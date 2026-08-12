#!/usr/bin/env bash
#
# prepopulate-r2-pypi.sh
# ------------------------------------------------------------------
# Purpose:
#   PyPI analog of prepopulate-r2.sh. Two subcommands:
#     1. list        - Enumerate PyPI artifacts (.whl / .tar.gz / .zip)
#                      in R1's cache via AQL and emit pkg==version pairs.
#     2. prepopulate - Run `jf pip download <pkg>==<version> --no-deps`
#                      for each entry through R2. Populates both the
#                      simple index metadata and the pinned artifact in
#                      R2's cache without pulling transitive deps or
#                      installing anything.
#
# HARD PREREQUISITE: 'pip' on PATH
#   'jf pip download' shells out to a binary literally named 'pip'.
#   On macOS Python 3.x ships 'pip3' but not 'pip' by default, so
#   every download silently fails with "executable file not found".
#
#   Fix before running:
#     macOS (Homebrew):  ln -s /opt/homebrew/bin/pip3 /opt/homebrew/bin/pip
#     macOS (system):    ln -s $(which pip3) /usr/local/bin/pip
#     Any:               alias pip=pip3   (add to shell rc)
#     Any:               python3 -m ensurepip --upgrade
#
#   Verify:  pip -V   (should print pip version, not "command not found")
#
# Why `jf pip download`:
#   Same logic as `jf npm pack` on the npm side —
#   - Curl HEAD on the artifact URL warms the .whl/.tar.gz but not the
#     simple/<pkg>/ index document that pip needs to resolve packages.
#   - `jf pip install` populates metadata + artifact but also pulls
#     all transitive dependencies, over-populating R2.
#   - `jf pip download --no-deps <pkg>==<version>` hits both endpoints
#     (metadata + pinned artifact) and skips deps. Mirrors R1 exactly.
#
# Usage:
#   ./prepopulate-r2-pypi.sh list \
#       --serverid <id> --sourceRepo <R1> \
#       [--downloadedWithin <dur>] [--createdWithin <dur>]
#
#   ./prepopulate-r2-pypi.sh prepopulate \
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
spec_file="pypi-spec-$$.json"
out_list="pypi-artifacts-$$.txt"
report_csv=""
PIP_WORK_DIR=""

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
  --sourceRepo <R1>        PyPI remote whose cache we enumerate.
  --targetRepo <R2>        PyPI remote to warm.
  --fromFile <PATH>        Read pkg==version list from a file (one per line, # for comments).
  --downloadedWithin <dur> AQL filter: stat.downloaded within duration (e.g. 1y).
  --createdWithin <dur>    AQL filter: created within duration.
  --dry-run                Print jf pip download commands, do not execute.
  --keep-work-dir          Do not delete the scratch pip work dir on exit
                           (useful for debugging).

Examples:
  $0 list --serverid sum2 --sourceRepo pypi-remote --downloadedWithin 1y
  $0 prepopulate --serverid sum2 --targetRepo pypi-remote2 --fromFile pkgs.txt

Prerequisites:
  - 'pip' binary on PATH (jf pip shells out to 'pip', NOT 'pip3'). Verify:
      pip -V
    If that fails but 'pip3 -V' works, create a link:
      ln -s /opt/homebrew/bin/pip3 /opt/homebrew/bin/pip   # macOS/Homebrew
      ln -s \$(which pip3) /usr/local/bin/pip              # macOS/system
    Or install pip: python3 -m ensurepip --upgrade
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

  # Match common PyPI artifact extensions.
  # If your cache has other formats (.tar.bz2, .egg), add them here.
  conditions+=", { \"\$or\": ["
  conditions+=" { \"name\": { \"\$match\": \"*.whl\" } }"
  conditions+=", { \"name\": { \"\$match\": \"*.tar.gz\" } }"
  conditions+=", { \"name\": { \"\$match\": \"*.zip\" } }"
  conditions+=" ] }"

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

# Convert AQL result to pkg==version.
#
# PyPI filename shapes:
#   Wheel:  <name>-<version>-<python>-<abi>-<platform>.whl
#           e.g. requests-2.31.0-py3-none-any.whl        -> requests==2.31.0
#                zope.interface-5.5.0-cp39-cp39-linux_x86_64.whl -> zope.interface==5.5.0
#   Sdist:  <name>-<version>.(tar.gz|zip)
#           e.g. requests-2.31.0.tar.gz                 -> requests==2.31.0
#                pkg-with-dashes-1.0.0.tar.gz           -> pkg-with-dashes==1.0.0
#
# Regex: name is everything up to '-<digit>', version is that digit-token
# up to the next '-' or end of string.
run_search() {
  log "Searching ${sourceRepo}-cache for PyPI artifacts..."
  jf rt s --spec="$spec_file" --server-id="$serverid" \
    | jq -r '
        .[] | .path
        | capture("(?<filename>[^/]+)$") | .filename
        | sub("\\.whl$"; "") | sub("\\.tar\\.gz$"; "") | sub("\\.zip$"; "")
        | capture("^(?<name>.+?)-(?<version>[0-9][^-]*)(?:-|$)")
        | "\(.name)==\(.version)"
      ' \
    | sort -u \
    > "$out_list"
  local count
  count=$(awk 'END{print NR}' "$out_list")
  log "Found ${count} pkg==version entries. List: ${out_list}"
}

# ---------- pip operations ----------
setup_pip_work_dir() {
  # Run `jf pipc` in the current working directory so the resulting
  # .jfrog/projects/pip.yaml is right there for the user to inspect
  # (`cat .jfrog/projects/pip.yaml`).
  # Downloaded artifacts go to /tmp to keep CWD clean.
  PIP_WORK_DIR=$(pwd)
  PIP_DOWNLOAD_DIR=$(mktemp -d)

  # Only clean up the .jfrog dir if we created it AND user didn't ask to keep it
  local jfrog_pre_existed="false"
  [[ -d "${PIP_WORK_DIR}/.jfrog" ]] && jfrog_pre_existed="true"

  if [[ "$keepWorkDir" != "true" ]]; then
    if [[ "$jfrog_pre_existed" == "true" ]]; then
      # There was a .jfrog dir before — only remove the projects/pip.yaml we add,
      # don't touch anything else the user may have configured.
      trap 'rm -f "${PIP_WORK_DIR}/.jfrog/projects/pip.yaml"; rm -rf "$PIP_DOWNLOAD_DIR"' EXIT
    else
      # Fresh .jfrog dir — safe to remove entirely
      trap 'rm -rf "${PIP_WORK_DIR}/.jfrog"; rm -rf "$PIP_DOWNLOAD_DIR"' EXIT
    fi
  else
    trap 'log "Config preserved: ${PIP_WORK_DIR}/.jfrog/projects/pip.yaml"; log "Downloads preserved: $PIP_DOWNLOAD_DIR"' EXIT
  fi

  log "Configuring jf pip resolver in: ${PIP_WORK_DIR}"

  # Explicitly remove any existing pip.yaml so jf pipc writes fresh config.
  # Without this, running the script against repo B after repo A can leave
  # the stale repo A config in place (jf pipc may silently no-op on
  # existing config depending on CLI version).
  local pip_yaml="${PIP_WORK_DIR}/.jfrog/projects/pip.yaml"
  if [[ -f "$pip_yaml" ]]; then
    local prev_repo
    prev_repo=$(awk '/repo:/{print $2; exit}' "$pip_yaml" 2>/dev/null)
    log "  Overriding existing config (previous resolver: ${prev_repo:-unknown})"
    rm -f "$pip_yaml"
  fi

  if ! ( cd "$PIP_WORK_DIR" && \
         jf pipc --repo-resolve="$targetRepo" \
                 --server-id-resolve="$serverid" \
                 >/dev/null 2>&1 ); then
    # Newer jf CLI uses jf pip-config
    if ! ( cd "$PIP_WORK_DIR" && \
           jf pip-config --repo-resolve="$targetRepo" \
                         --server-id-resolve="$serverid" \
                         >/dev/null 2>&1 ); then
      log "ERROR: could not configure jf pip resolver."
      log "       Check 'jf pipc --help' or 'jf pip-config --help'."
      exit 1
    fi
  fi

  log "Resolver config written to ${pip_yaml}"
}

# Run `jf pip download <pkg>==<version> --no-deps` in the scratch dir.
prepopulate_one() {
  local pkgver="$1"

  if [[ "$dryrun" == "true" ]]; then
    log "  DRY   jf pip download ${pkgver} --no-deps"
    echo "${pkgver},DRY" >> "$report_csv"
    return
  fi

  printf "[%s]   ...   %s" "$(date '+%H:%M:%S')" "${pkgver}"

  local pip_out_file="/tmp/prepop_pip_out.$$"
  local rc=0
  if ( cd "$PIP_WORK_DIR" && \
       jf pip download "$pkgver" --no-deps -d "$PIP_DOWNLOAD_DIR" \
     ) >"$pip_out_file" 2>&1; then
    rc=0
  else
    rc=$?
  fi

  local status
  if [[ $rc -eq 0 ]]; then
    status="200"
  elif grep -qi "executable file not found\|pip.*not found in.*PATH\|no such file or directory.*pip" "$pip_out_file"; then
    # jf pip shells out to real pip; if pip isn't installed, this fires
    # for every entry with the same error — surface it as FAIL not 404
    status="NOPIP"
  elif grep -qi "404\|no matching distribution\|could not find a version" "$pip_out_file"; then
    status="404"
  elif grep -qi "401\|403\|forbidden\|unauthorized" "$pip_out_file"; then
    status="403"
  else
    status="FAIL"
  fi

  local err_line
  err_line=$(tail -1 "$pip_out_file" | tr -d '\n' | head -c 120)

  # If pip is missing, print a clear one-time hint and abort — no point
  # continuing when every entry will fail identically
  if [[ "$status" == "NOPIP" ]]; then
    printf "\r[%s]   " "$(date '+%H:%M:%S')"
    printf "FAIL  [---]  %s  (pip binary not found on PATH)\n" "${pkgver}"
    log "ERROR: 'jf pip download' shells out to real 'pip' which isn't on PATH."
    log "       Fix: install pip (python3 -m ensurepip --upgrade), or"
    log "       alias/symlink pip -> pip3 (macOS default is pip3, not pip)."
    log "       Then rerun this script."
    rm -f "$pip_out_file"
    exit 1
  fi

  rm -f "$pip_out_file"

  # Remove downloaded artifacts to keep disk usage bounded
  rm -rf "$PIP_DOWNLOAD_DIR"/* 2>/dev/null || true

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
  report_csv="pypi-prepop-report-${targetRepo}-$(date +%Y%m%d-%H%M%S).csv"
  echo "pkg_version,status" > "$report_csv"

  [[ "$dryrun" == "true" ]] && log "DRY RUN - no jf pip download commands will run"

  # Preflight pip. 'jf pip download' shells out to 'pip' (not pip3),
  # so a machine with only pip3 installed will fail every entry.
  # We run 'pip -V' rather than just command -v to catch broken installs
  # (e.g. a pip binary that exists but can't import its own package).
  if [[ "$dryrun" != "true" ]]; then
    if ! pip -V >/dev/null 2>&1; then
      log "ERROR: 'pip -V' failed. 'jf pip download' will not work."
      if command -v pip3 >/dev/null 2>&1; then
        log "       You have 'pip3' at $(command -v pip3) but 'jf pip' calls 'pip' specifically."
        log "       Fix (Homebrew macOS): ln -s /opt/homebrew/bin/pip3 /opt/homebrew/bin/pip"
        log "       Fix (system macOS):   ln -s \$(which pip3) /usr/local/bin/pip"
        log "       Fix (any):            alias pip=pip3   (add to ~/.zshrc or ~/.bashrc)"
      else
        log "       Install Python + pip. On macOS: python3 -m ensurepip --upgrade"
      fi
      log "       Verify with: pip -V"
      exit 1
    fi
    log "pip: $(pip -V)"
  fi

  setup_pip_work_dir
  log "Pre-populating ${targetRepo} via 'jf pip download'..."

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

  log "Complete. ${count} pkg==version entries processed. Report: ${report_csv}"
  log "Summary:"
  awk -F',' 'NR>1 {c[$2]++} END {for (s in c) printf "  %-6s : %d\n", s, c[s]}' \
    "$report_csv" | sort
}

# ---------- Subcommands ----------
cmd_list() {
  [[ -z "$sourceRepo" ]] && { log "ERROR: --sourceRepo required"; usage; }
  log "=== List mode (pypi) ==="
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

  log "=== Prepopulate mode (pypi) ==="
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