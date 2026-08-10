#!/usr/bin/env bash
#
# prepopulate-r2.sh
# ------------------------------------------------------------------
# Purpose:
#   Two modes, both driven by jf CLI + AQL spec files:
#     1. list        - List artifacts in R1's cache. Optional time filter.
#     2. prepopulate - Trigger R2 to fetch each listed artifact from its
#                      upstream, warming R2's cache and forcing Curation
#                      to evaluate every one.
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
#       [--resolveVia remote|virtual] [--virtualRepo <V1>] [--dry-run]
#
# Duration strings match AQL: 1d, 1w, 6mo, 1y (uses $before internally,
# inverted with $not for "within" semantics via $gt ISO date).
# ------------------------------------------------------------------

set -euo pipefail

# ---------- Defaults ----------
serverid=""
sourceRepo=""
targetRepo=""
downloadedWithin=""
createdWithin=""
fromFile=""
resolveVia="remote"
virtualRepo=""
dryrun="false"
spec_file="prepop-spec-$$.json"
out_list="artifacts-$$.txt"
report_csv=""
connect_timeout="10"

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
     [--resolveVia remote|virtual] [--virtualRepo <V1>] [--dry-run]
     [--connect-timeout <sec>]

Duration format: 1d, 1w, 6mo, 1y (same as your cleanup script).

Timeouts (prepopulate only):
  --connect-timeout <sec>  Max time to establish TCP+TLS connection to R2.
                           Default: 10s. Trips fast if R2 unreachable.
                           No ceiling on transfer once connected — R2 fetches
                           run as long as the upstream needs.

Examples:
  # List everything in R1
  $0 list --serverid mytenant --sourceRepo npm-remote

  # List npm packages downloaded in the last year
  $0 list --serverid mytenant --sourceRepo npm-remote --downloadedWithin 1y

  # Pre-populate R2 from R1 (last year of activity), dry run first
  $0 prepopulate --serverid mytenant --targetRepo npm-remote-new \\
       --sourceRepo npm-remote --downloadedWithin 1y --dry-run

  # Pre-populate R2 from a reviewed file
  $0 prepopulate --serverid mytenant --targetRepo npm-remote-new \\
       --fromFile reviewed-artifacts.txt

  # Same but through the virtual (dress rehearsal)
  $0 prepopulate --serverid mytenant --targetRepo npm-remote-new \\
       --fromFile reviewed.txt --resolveVia virtual --virtualRepo npm-virtual
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
    --resolveVia)        resolveVia="$2"; shift 2 ;;
    --virtualRepo)       virtualRepo="$2"; shift 2 ;;
    --dry-run)           dryrun="true"; shift ;;
    --connect-timeout)   connect_timeout="$2"; shift 2 ;;
    --help|-h)           usage ;;
    *) log "ERROR: unknown flag $1"; usage ;;
  esac
done

# ---------- Preflight ----------
if [[ -z "$serverid" ]]; then
  log "ERROR: --serverid is required"
  usage
fi

if ! jf c show "$serverid" >/dev/null 2>&1; then
  log "ERROR: server ID '$serverid' not configured. Run 'jf c add' first."
  exit 1
fi

# Extract URL + access token from the configured server, ONCE.
# jf c export emits base64-encoded JSON; decode and pull the fields we need.
server_json=$(jf c export "$serverid" 2>/dev/null | base64 --decode 2>/dev/null || true)
if [[ -z "$server_json" ]]; then
  log "ERROR: could not export server config for '$serverid'"
  exit 1
fi

JF_URL=$(echo "$server_json" | jq -r '.url // .artifactoryUrl // empty' | sed 's|/$||')
JF_TOKEN=$(echo "$server_json" | jq -r '.accessToken // empty')
JF_USER=$(echo "$server_json" | jq -r '.user // empty')
JF_PASS=$(echo "$server_json" | jq -r '.password // empty')

if [[ -z "$JF_URL" ]]; then
  log "ERROR: could not parse artifactory URL from server config"
  exit 1
fi

# Build the auth arg once for reuse
if [[ -n "$JF_TOKEN" ]]; then
  AUTH_ARG=(-H "Authorization: Bearer ${JF_TOKEN}")
elif [[ -n "$JF_USER" && -n "$JF_PASS" ]]; then
  AUTH_ARG=(-u "${JF_USER}:${JF_PASS}")
else
  log "ERROR: no credentials found in server config"
  exit 1
fi

# Ensure URL points at the /artifactory root
[[ "$JF_URL" != */artifactory ]] && JF_URL="${JF_URL}/artifactory"

# ---------- AQL builder ----------
# NOTE: AQL "$before" matches items OLDER than the duration.
#       For "within the last <dur>" semantics we would need "$last" which AQL
#       does not expose. Instead we invert client-side: list all first, then
#       filter by ISO cutoff on stat.downloaded / created returned in results.
# But to keep the query itself narrow (fewer results returned), we use $before
# on the OPPOSITE field to prune obvious matches, then a jq post-filter to
# enforce the "within" semantics precisely.
#
# Actually simplest: use jq to post-filter on the ISO timestamp AQL returns.

# Compute ISO cutoff for a duration like 1y, 6mo, 1w, 1d, 30d
iso_cutoff_for_duration() {
  local dur="$1"
  local n unit
  # split into number + unit
  n=$(echo "$dur" | sed -E 's/([0-9]+).*/\1/')
  unit=$(echo "$dur" | sed -E 's/[0-9]+//')

  local days
  case "$unit" in
    d)  days=$n ;;
    w)  days=$((n * 7)) ;;
    mo) days=$((n * 30)) ;;
    y)  days=$((n * 365)) ;;
    *) log "ERROR: unknown duration unit '$unit' (use d, w, mo, y)"; exit 1 ;;
  esac

  # portable date arithmetic
  if date -u -d "${days} days ago" +"%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
    date -u -d "${days} days ago" +"%Y-%m-%dT%H:%M:%SZ"
  else
    date -u -v-"${days}"d +"%Y-%m-%dT%H:%M:%SZ"
  fi
}

# Write an AQL spec file that lists R1 cache contents
write_spec() {
  local repo_cache="${sourceRepo}-cache"

  # Base conditions
  local conditions="{ \"\$and\": [ { \"repo\": \"${repo_cache}\" }, { \"type\": \"file\" }"

  # Exclude package-manager metadata that isn't a real artifact:
  #   - npm registry documents under .npm/ (package.json files)
  #   - checksum sidecars (.sha1, .sha256, .md5) - regenerated on cache
  #   - Maven maven-metadata.xml (regenerated by indexer)
  #   - manifest.json (Docker manifests, handled differently)
  conditions+=", { \"path\": { \"\$nmatch\": \".npm/*\" } }"
  conditions+=", { \"name\": { \"\$nmatch\": \"*.sha1\" } }"
  conditions+=", { \"name\": { \"\$nmatch\": \"*.sha256\" } }"
  conditions+=", { \"name\": { \"\$nmatch\": \"*.md5\" } }"
  conditions+=", { \"name\": { \"\$nmatch\": \"maven-metadata.xml*\" } }"

  # Time filters - $gt with ISO cutoff (proven to work with jf rt s --spec)
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
{
  "files": [
    {
      "aql": {
        "items.find": ${conditions}
      }
    }
  ]
}
EOF

  log "AQL spec written: $spec_file"
}

# Run the search - AQL returns .path (folder) and .name (filename) separately.
# We join them and strip the repo-cache prefix so the output is ready to feed
# straight into the R2 fetch step.
run_search() {
  log "Searching ${sourceRepo}-cache..."
  jf rt s --spec="$spec_file" --server-id="$serverid" \
    | jq -r --arg prefix "${sourceRepo}-cache/" \
        '.[] | .path | sub("^" + $prefix; "")' \
    > "$out_list"
  local count
  count=$(wc -l < "$out_list" | tr -d ' ')
  log "Found ${count} artifacts. List: ${out_list}"
}

# ---------- Pre-populate ----------
# Trigger R2 to fetch each listed artifact via HEAD (fetch+cache on Artifactory
# side, no payload to client). Uses jf rt curl so serverid handles auth+URL.
prepopulate_one() {
  local rel_path="$1"    # already repo-relative from run_search

  # Determine target endpoint
  local endpoint
  if [[ "$resolveVia" == "virtual" ]]; then
    endpoint="/${virtualRepo}/${rel_path}"
  else
    endpoint="/${targetRepo}/${rel_path}"
  fi

  if [[ "$dryrun" == "true" ]]; then
    log "  DRY   HEAD ${JF_URL}${endpoint}"
    echo "${rel_path},DRY" >> "$report_csv"
    return
  fi

  # Print "starting" line immediately so operator sees progress in real time
  printf "[%s]   ...   %s" "$(date '+%H:%M:%S')" "${rel_path}"

  # Capture curl status cleanly. Do NOT use `|| echo "000"` — that concatenates
  # with any partial status curl already wrote to stdout.
  local status curl_err_file="/tmp/prepop_curl_err.$$"
  local rc
  status=$(curl -sS -o /dev/null -w "%{http_code}" \
             "${AUTH_ARG[@]}" \
             -X HEAD \
             --connect-timeout "${connect_timeout}" \
             "${JF_URL}${endpoint}" 2>"$curl_err_file")
  rc=$?

  local curl_err=""
  if [[ $rc -ne 0 ]]; then
    curl_err=$(tr '\n' ' ' < "$curl_err_file")
    # If curl failed before printing anything, force 000
    [[ -z "$status" || ! "$status" =~ ^[0-9]{3}$ ]] && status="000"
  fi
  rm -f "$curl_err_file"

  # Overwrite the "..." line with the final status
  printf "\r[%s]   " "$(date '+%H:%M:%S')"
  case "$status" in
    200) printf "OK    %s\n" "${rel_path}" ;;
    403) printf "BLOCK %s  (Curation denied)\n" "${rel_path}" ;;
    404) printf "MISS  %s  (not in upstream)\n" "${rel_path}" ;;
    000) printf "FAIL  %s  (%s)\n" "${rel_path}" "${curl_err:-unknown error}" ;;
    *)   printf "HTTP %s  %s\n" "${status}" "${rel_path}" ;;
  esac

  echo "${rel_path},${status}" >> "$report_csv"
}

prepopulate_all() {
  local input_list="$1"
  report_csv="prepop-report-${targetRepo}-$(date +%Y%m%d-%H%M%S).csv"
  echo "artifact_path,http_status" > "$report_csv"

  [[ "$dryrun" == "true" ]] && log "DRY RUN - no requests will hit R2"
  log "Pre-populating ${targetRepo} via ${resolveVia}..."

  local count=0
  while IFS= read -r ARTIFACT; do
    [[ -z "$ARTIFACT" ]] && continue
    [[ "$ARTIFACT" == \#* ]] && continue      # allow # comments in file input
    prepopulate_one "$ARTIFACT"
    count=$((count + 1))
  done < "$input_list"

  log "Complete. ${count} artifacts processed. Report: ${report_csv}"
  log "Summary:"
  awk -F',' 'NR>1 {c[$2]++} END {for (s in c) printf "  HTTP %s : %d\n", s, c[s]}' \
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
    log "ERROR: --sourceRepo and --fromFile are mutually exclusive"
    exit 1
  fi
  if [[ -z "$sourceRepo" && -z "$fromFile" ]]; then
    log "ERROR: one of --sourceRepo or --fromFile is required"
    usage
  fi
  if [[ "$resolveVia" == "virtual" && -z "$virtualRepo" ]]; then
    log "ERROR: --resolveVia virtual requires --virtualRepo"
    exit 1
  fi

  log "=== Prepopulate mode ==="
  log "Target: ${targetRepo}   Resolve via: ${resolveVia}   Dry-run: ${dryrun}"

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
