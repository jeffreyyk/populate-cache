#!/usr/bin/env bash
#
# prepopulate-r2.sh
# ------------------------------------------------------------------
# Purpose:
#   Two subcommands:
#     1. list        - Enumerate npm tarballs in R1's cache via AQL and
#                      emit pkg@version pairs.
#     2. prepopulate - Run `jf npm pack pkg@version` for each entry
#                      through R2. Populates both the tarball and the
#                      npm metadata (.npm/<pkg>/package.json) in R2's
#                      cache without pulling transitive dependencies.
#
# Why `jf npm pack` instead of curl:
#   - Curl HEAD on the tarball URL populates the tarball but NOT the
#     .npm/<pkg>/package.json metadata document. Real npm clients hit
#     both, and some Curation policies inspect the metadata.
#   - `jf npm install` populates metadata + tarball, but also pulls
#     all transitive dependencies, over-populating R2 with content
#     R1 never had.
#   - `jf npm pack pkg@version` hits both endpoints (metadata + tarball
#     for the exact pinned version) and skips dependency resolution.
#     Mirrors R1's cache shape exactly.
#
# Usage:
#   ./prepopulate-r2.sh list \
#       --serverid <id> --sourceRepo <R1> \
#       [--downloadedWithin <dur>] [--createdWithin <dur>]
#
#   ./prepopulate-r2.sh prepopulate \
#       --serverid <id> --targetRepo <R2> \
#       ( --sourceRepo <R1> [--downloadedWithin <dur>] [--createdWithin <dur>] \
#       | --fromFile <PATH> ) \
#       [--dry-run] [--keep-work-dir]
#
# Duration strings: 1d, 1w, 6mo, 1y
# ------------------------------------------------------------------

set -euo pipefail

# ---------- Defaults ----------
serverid=""
sourceRepo=""
targetRepo=""
downloadedWithin=""
createdWithin=""
fromFile=""
dryrun="false"
keepWorkDir="false"
spec_file="prepop-spec-$$.json"
out_list="artifacts-$$.txt"
report_csv=""
NPM_WORK_DIR=""

# ---------- Utility ----------
log() { echo "[$(date '+%H:%M:%S')] $*"; }

usage() {
  cat <<EOF
Usage:
  $0 list --serverid <id> --sourceRepo <R1>
     [--downloadedWithin <dur>] [--createdWithin <dur>]

  $0 prepopulate --serverid <id> --targetRepo <R2>
     ( --sourceRepo <R1> [--downloadedWithin <dur>] [--createdWithin <dur>]
     | --fromFile <PATH> )
     [--dry-run] [--keep-work-dir]

Flags:
  --serverid <id>          JFrog CLI server ID.
  --sourceRepo <R1>        npm remote whose cache we enumerate.
  --targetRepo <R2>        npm remote to warm.
  --fromFile <PATH>        Read pkg@version list from a file (one per line, # for comments).
  --downloadedWithin <dur> AQL filter: stat.downloaded within duration (e.g. 1y).
  --createdWithin <dur>    AQL filter: created within duration.
  --dry-run                Print jf npm pack commands, do not execute.
  --keep-work-dir          Do not delete the scratch npm work dir on exit
                           (useful for debugging).

Examples:
  $0 list --serverid sum2 --sourceRepo npm-remote --downloadedWithin 1y
  $0 prepopulate --serverid sum2 --targetRepo npm-remote2 --fromFile pkgs.txt
EOF
  exit 1
}

# ---------- Parse args ----------
subcommand="${1:-}"
shift || usage

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serverid)          serverid="$2"; shift 2 ;;
    --sourceRepo)        sourceRepo="$2"; shift 2 ;;
    --targetRepo)        targetRepo="$2"; shift 2 ;;
    --downloadedWithin)  downloadedWithin="$2"; shift 2 ;;
    --createdWithin)     createdWithin="$2"; shift 2 ;;
    --fromFile)          fromFile="$2"; shift 2 ;;
    --dry-run)           dryrun="true"; shift ;;
    --keep-work-dir)     keepWorkDir="true"; shift ;;
    --help|-h)           usage ;;
    *) log "ERROR: unknown flag $1"; usage ;;
  esac
done

# ---------- Preflight ----------
[[ -z "$serverid" ]] && { log "ERROR: --serverid is required"; usage; }
if ! jf c show "$serverid" >/dev/null 2>&1; then
  log "ERROR: server ID '$serverid' not configured. Run 'jf c add' first."
  exit 1
fi

# ---------- AQL listing ----------
iso_cutoff_for_duration() {
  local dur="$1"
  local n unit
  n=$(echo "$dur" | sed -E 's/([0-9]+).*/\1/')
  unit=$(echo "$dur" | sed -E 's/[0-9]+//')
  local days
  case "$unit" in
    d)  days=$n ;;
    w)  days=$((n * 7)) ;;
    mo) days=$((n * 30)) ;;
    y)  days=$((n * 365)) ;;
    *) log "ERROR: unknown duration unit '$unit'"; exit 1 ;;
  esac
  if date -u -d "${days} days ago" +"%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
    date -u -d "${days} days ago" +"%Y-%m-%dT%H:%M:%SZ"
  else
    date -u -v-"${days}"d +"%Y-%m-%dT%H:%M:%SZ"
  fi
}

write_spec() {
  local repo_cache="${sourceRepo}-cache"
  local conditions="{ \"\$and\": [ { \"repo\": \"${repo_cache}\" }, { \"type\": \"file\" }"

  # Only match actual .tgz tarballs; exclude metadata, checksums, and
  # anything under .npm/ (registry documents, not artifacts).
  conditions+=", { \"name\": { \"\$match\": \"*.tgz\" } }"
  conditions+=", { \"path\": { \"\$nmatch\": \".npm/*\" } }"

  if [[ -n "$downloadedWithin" ]]; then
    local cutoff
    cutoff=$(iso_cutoff_for_duration "$downloadedWithin")
    conditions+=", { \"stat.downloaded\": { \"\$gt\": \"${cutoff}\" } }"
    log "Filter: stat.downloaded > ${cutoff} (within ${downloadedWithin})"
  fi
  if [[ -n "$createdWithin" ]]; then
    local cutoff
    cutoff=$(iso_cutoff_for_duration "$createdWithin")
    conditions+=", { \"created\": { \"\$gt\": \"${cutoff}\" } }"
    log "Filter: created > ${cutoff} (within ${createdWithin})"
  fi

  conditions+=" ] }"
  cat > "$spec_file" <<EOF
{ "files": [ { "aql": { "items.find": ${conditions} } } ] }
EOF
}

# Convert AQL result to pkg@version.
#   path shape: eslint/-/eslint-8.57.0.tgz            -> eslint@8.57.0
#   path shape: @babel/code-frame/-/code-frame-7.29.7.tgz -> @babel/code-frame@7.29.7
#
# jf rt s returns .path with the tarball filename appended and the
# <repo>-cache/ prefix in front. We strip both, then split on "/-/".
run_search() {
  log "Searching ${sourceRepo}-cache for tarballs..."
  jf rt s --spec="$spec_file" --server-id="$serverid" \
    | jq -r --arg prefix "${sourceRepo}-cache/" '
        .[] | .path
        | sub("^" + $prefix; "")
        | capture("(?<pkg>.+)/-/(?<name>[^/]+)\\.tgz$")
        | .pkg as $pkg
        | (.name | capture("(?<n>.+)-(?<v>[0-9][^-]*.*)$")) as $nv
        | "\($pkg)@\($nv.v)"
      ' \
    | sort -u \
    > "$out_list"
  local count
  count=$(wc -l < "$out_list" | tr -d ' ')
  log "Found ${count} pkg@version entries. List: ${out_list}"
}

# ---------- npm operations ----------
setup_npm_work_dir() {
  NPM_WORK_DIR=$(mktemp -d)
  if [[ "$keepWorkDir" != "true" ]]; then
    trap 'rm -rf "$NPM_WORK_DIR"' EXIT
  else
    trap 'log "Scratch dir preserved: $NPM_WORK_DIR"' EXIT
  fi

  log "Configuring jf npm resolver in scratch dir: ${NPM_WORK_DIR}"
  if ! ( cd "$NPM_WORK_DIR" && \
         jf npmc --repo-resolve="$targetRepo" \
                 --server-id-resolve="$serverid" \
                 >/dev/null 2>&1 ); then
    # Newer jf CLI uses jf npm-config
    if ! ( cd "$NPM_WORK_DIR" && \
           jf npm-config --repo-resolve="$targetRepo" \
                         --server-id-resolve="$serverid" \
                         >/dev/null 2>&1 ); then
      log "ERROR: could not configure jf npm resolver."
      log "       Check 'jf npmc --help' or 'jf npm-config --help'."
      exit 1
    fi
  fi
}

# Run `jf npm pack pkg@version` in the scratch dir.
# Pack fetches metadata + tarball through R2 without pulling deps.
prepopulate_one() {
  local pkgver="$1"

  if [[ "$dryrun" == "true" ]]; then
    log "  DRY   jf npm pack ${pkgver}"
    echo "${pkgver},DRY" >> "$report_csv"
    return
  fi

  printf "[%s]   ...   %s" "$(date '+%H:%M:%S')" "${pkgver}"

  local npm_out_file="/tmp/prepop_npm_out.$$"
  local rc=0
  if ( cd "$NPM_WORK_DIR" && jf npm pack "$pkgver" ) >"$npm_out_file" 2>&1; then
    rc=0
  else
    rc=$?
  fi

  local status
  if [[ $rc -eq 0 ]]; then
    status="200"
  elif grep -qi "404\|not found\|no matching version\|is not in the npm registry" "$npm_out_file"; then
    status="404"
  elif grep -qi "401\|403\|forbidden\|unauthorized\|EAUTH\|denied" "$npm_out_file"; then
    status="403"
  else
    status="FAIL"
  fi

  local err_line
  err_line=$(tail -1 "$npm_out_file" | tr -d '\n' | head -c 120)
  rm -f "$npm_out_file"

  # Remove the .tgz file left in the work dir so disk usage doesn't grow
  find "$NPM_WORK_DIR" -maxdepth 1 -name '*.tgz' -delete 2>/dev/null || true

  printf "\r[%s]   " "$(date '+%H:%M:%S')"
  case "$status" in
    200)  printf "OK    [200]  %s\n" "${pkgver}" ;;
    403)  printf "BLOCK [403]  %s  (Curation denied or auth failed)\n" "${pkgver}" ;;
    404)  printf "MISS  [404]  %s  (not in upstream)\n" "${pkgver}" ;;
    FAIL) printf "FAIL  [---]  %s  (%s)\n" "${pkgver}" "${err_line}" ;;
  esac

  echo "${pkgver},${status}" >> "$report_csv"
}

prepopulate_all() {
  local input_list="$1"
  report_csv="prepop-report-${targetRepo}-$(date +%Y%m%d-%H%M%S).csv"
  echo "pkg_version,status" > "$report_csv"

  [[ "$dryrun" == "true" ]] && log "DRY RUN - no jf npm pack commands will run"

  # Preflight npm (required by jf npm pack)
  if [[ "$dryrun" != "true" ]] && ! command -v npm >/dev/null 2>&1; then
    log "ERROR: 'npm' binary not found on PATH. Install Node.js first."
    exit 1
  fi

  setup_npm_work_dir
  log "Pre-populating ${targetRepo} via 'jf npm pack'..."

  local count=0
  while IFS= read -r LINE || [[ -n "$LINE" ]]; do
    LINE="${LINE%$'\r'}"
    LINE="${LINE#"${LINE%%[![:space:]]*}"}"
    LINE="${LINE%"${LINE##*[![:space:]]}"}"
    [[ -z "$LINE" ]] && continue
    [[ "$LINE" == \#* ]] && continue
    prepopulate_one "$LINE"
    count=$((count + 1))
  done < "$input_list"

  log "Complete. ${count} pkg@version entries processed. Report: ${report_csv}"
  log "Summary:"
  awk -F',' 'NR>1 {c[$2]++} END {for (s in c) printf "  %-6s : %d\n", s, c[s]}' \
    "$report_csv" | sort
}

# ---------- Subcommands ----------
cmd_list() {
  [[ -z "$sourceRepo" ]] && { log "ERROR: --sourceRepo required"; usage; }
  log "=== List mode ==="
  log "Source: ${sourceRepo}"
  write_spec
  run_search
  log "=== Done. List: ${out_list} ==="
}

cmd_prepopulate() {
  [[ -z "$targetRepo" ]] && { log "ERROR: --targetRepo required"; usage; }

  if [[ -n "$sourceRepo" && -n "$fromFile" ]]; then
    log "ERROR: --sourceRepo and --fromFile are mutually exclusive"; exit 1
  fi
  if [[ -z "$sourceRepo" && -z "$fromFile" ]]; then
    log "ERROR: one of --sourceRepo or --fromFile is required"; usage
  fi

  log "=== Prepopulate mode ==="
  log "Target: ${targetRepo}"
  log "Dry-run: ${dryrun}"

  local input_list
  if [[ -n "$sourceRepo" ]]; then
    log "Source: AQL against ${sourceRepo}"
    write_spec
    run_search
    input_list="$out_list"
  else
    log "Source: file ${fromFile}"
    [[ ! -r "$fromFile" ]] && { log "ERROR: cannot read ${fromFile}"; exit 1; }
    input_list="$fromFile"
  fi

  prepopulate_all "$input_list"
  log "=== Done ==="
}

# ---------- Main ----------
case "$subcommand" in
  list)        cmd_list ;;
  prepopulate) cmd_prepopulate ;;
  *)           usage ;;
esac