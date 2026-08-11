#!/usr/bin/env bash
#
# check-upstream.sh
# ------------------------------------------------------------------
# Purpose:
#   For each artifact in the input list, check whether it still exists
#   in the upstream registry configured for the source remote repo.
#
#   Produces a report of what's MISSING from upstream - the input to
#   the rescue-local remediation pattern (see README).
#
# Usage:
#   ./check-upstream.sh --serverid <id> --sourceRepo <repo>
#       ( --fromFile <path>
#       | [--downloadedWithin <dur>] [--createdWithin <dur>] )
#       [--connect-timeout <sec>]
#
#   --serverid <id>          JFrog CLI server ID
#   --sourceRepo <repo>      R1 remote whose upstream URL we test against
#   --fromFile <path>        Optional. Read artifact list from a file.
#                            If omitted, list R1 via AQL with optional filters.
#   --downloadedWithin <dur> AQL filter: stat.downloaded within duration (e.g. 1y)
#   --createdWithin <dur>    AQL filter: created within duration
#   --connect-timeout <sec>  TCP+TLS connect timeout to upstream. Default 10s.
# ------------------------------------------------------------------

set -euo pipefail

# ---------- Defaults ----------
serverid=""
sourceRepo=""
fromFile=""
downloadedWithin=""
createdWithin=""
connect_timeout="10"
verbose="false"
spec_file="check-spec-$$.json"
out_list="check-list-$$.txt"
report_csv=""

# ---------- Utility ----------
log() { echo "[$(date '+%H:%M:%S')] $*"; }

usage() {
  cat <<EOF
Usage:
  $0 --serverid <id> --sourceRepo <repo>
     ( --fromFile <path>
     | [--downloadedWithin <dur>] [--createdWithin <dur>] )
     [--connect-timeout <sec>]

Examples:
  # Check a pre-built list against the R1 upstream
  $0 --serverid sum2 --sourceRepo npm-remote --fromFile artifacts.txt

  # Check everything R1 has cached in the last year
  $0 --serverid sum2 --sourceRepo npm-remote --downloadedWithin 1y
EOF
  exit 1
}

# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --serverid)          serverid="$2"; shift 2 ;;
    --sourceRepo)        sourceRepo="$2"; shift 2 ;;
    --fromFile)          fromFile="$2"; shift 2 ;;
    --downloadedWithin)  downloadedWithin="$2"; shift 2 ;;
    --createdWithin)     createdWithin="$2"; shift 2 ;;
    --connect-timeout)   connect_timeout="$2"; shift 2 ;;
    --verbose|-v)        verbose="true"; shift ;;
    --help|-h)           usage ;;
    *) log "ERROR: unknown flag $1"; usage ;;
  esac
done

# ---------- Preflight ----------
[[ -z "$serverid"   ]] && { log "ERROR: --serverid is required"; usage; }
[[ -z "$sourceRepo" ]] && { log "ERROR: --sourceRepo is required"; usage; }

if ! jf c show "$serverid" >/dev/null 2>&1; then
  log "ERROR: server ID '$serverid' not configured. Run 'jf c add' first."
  exit 1
fi

# ---------- Upstream URL discovery ----------
get_upstream_url() {
  local url
  url=$(jf rt curl -X GET "/api/repositories/${sourceRepo}" --server-id="$serverid" 2>/dev/null \
        | jq -r '.url // empty' | sed 's|/$||')
  if [[ -z "$url" ]]; then
    log "ERROR: could not read upstream URL for ${sourceRepo}"
    log "       (is it a remote repo? does the token have read access?)"
    exit 1
  fi
  echo "$url"
}

# ---------- AQL listing (when --fromFile not given) ----------
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
    *) log "ERROR: unknown duration unit '$unit' (use d, w, mo, y)"; exit 1 ;;
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

  # Exclude non-artifact metadata (same as prepopulate-r2.sh)
  conditions+=", { \"path\": { \"\$nmatch\": \".npm/*\" } }"
  conditions+=", { \"name\": { \"\$nmatch\": \"*.sha1\" } }"
  conditions+=", { \"name\": { \"\$nmatch\": \"*.sha256\" } }"
  conditions+=", { \"name\": { \"\$nmatch\": \"*.md5\" } }"
  conditions+=", { \"name\": { \"\$nmatch\": \"maven-metadata.xml*\" } }"

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

# ---------- Upstream check (per artifact) ----------
check_one() {
  local rel_path="$1"
  local upstream_base="$2"
  local url="${upstream_base}/${rel_path}"

  printf "[%s]   ...   %s" "$(date '+%H:%M:%S')" "${rel_path}"
  [[ "$verbose" == "true" ]] && printf "\n[%s]   URL   %s" "$(date '+%H:%M:%S')" "${url}"

  # Guarded curl - -L follows redirects (upstreams often redirect to CDNs).
  # -I is stricter than -X HEAD: closes the connection after headers even if
  # the server misbehaves and tries to stream a body.
  local status=0 rc=0 curl_err_file="/tmp/check_curl_err.$$"
  local timing_fmt="%{http_code}"
  [[ "$verbose" == "true" ]] && timing_fmt="%{http_code}|dns=%{time_namelookup} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total}"

  local raw
  if raw=$(curl -sSLI -o /dev/null -w "$timing_fmt" \
                --connect-timeout "${connect_timeout}" \
                "${url}" 2>"$curl_err_file"); then
    rc=0
  else
    rc=$?
  fi

  # Split status from timing detail (if verbose)
  status="${raw%%|*}"
  local timing_detail=""
  [[ "$verbose" == "true" && "$raw" == *"|"* ]] && timing_detail="${raw#*|}"

  local curl_err=""
  if [[ $rc -ne 0 ]]; then
    curl_err=$(tr '\n' ' ' < "$curl_err_file")
    [[ -z "$status" || ! "$status" =~ ^[0-9]{3}$ ]] && status="000"
  fi
  rm -f "$curl_err_file"

  printf "\r[%s]   " "$(date '+%H:%M:%S')"
  case "$status" in
    200) printf "OK    [200]  %s\n" "${rel_path}" ;;
    404) printf "MISS  [404]  %s  (missing from upstream)\n" "${rel_path}" ;;
    403|401) printf "AUTH  [%s]  %s  (upstream requires auth)\n" "${status}" "${rel_path}" ;;
    000) printf "FAIL  [---]  %s  (%s)\n" "${rel_path}" "${curl_err:-unknown error}" ;;
    *)   printf "      [%s]  %s\n" "${status}" "${rel_path}" ;;
  esac
  [[ -n "$timing_detail" ]] && log "         timing: ${timing_detail}"

  echo "${rel_path},${status}" >> "$report_csv"
}

check_all() {
  local input_list="$1"
  local upstream_base="$2"
  report_csv="upstream-check-${sourceRepo}-$(date +%Y%m%d-%H%M%S).csv"
  echo "artifact_path,upstream_status" > "$report_csv"

  log "Upstream base: ${upstream_base}"
  log "Checking artifacts..."

  local count=0
  while IFS= read -r ARTIFACT || [[ -n "$ARTIFACT" ]]; do
    # Strip trailing \r (Windows line endings) and surrounding whitespace
    ARTIFACT="${ARTIFACT%$'\r'}"
    ARTIFACT="${ARTIFACT#"${ARTIFACT%%[![:space:]]*}"}"
    ARTIFACT="${ARTIFACT%"${ARTIFACT##*[![:space:]]}"}"
    [[ -z "$ARTIFACT" ]] && continue
    [[ "$ARTIFACT" == \#* ]] && continue
    check_one "$ARTIFACT" "$upstream_base"
    count=$((count + 1))
  done < "$input_list"

  log "Complete. ${count} artifacts checked. Report: ${report_csv}"
  log "Summary:"
  awk -F',' 'NR>1 {c[$2]++} END {for (s in c) printf "  HTTP %s : %d\n", s, c[s]}' \
    "$report_csv" | sort

  # Extract just the missing ones into a separate file for the rescue-local step
  local missing_file="upstream-missing-${sourceRepo}-$(date +%Y%m%d-%H%M%S).txt"
  awk -F',' 'NR>1 && $2 == "404" {print $1}' "$report_csv" > "$missing_file"
  local missing_count
  missing_count=$(wc -l < "$missing_file" | tr -d ' ')
  if [[ $missing_count -gt 0 ]]; then
    log "${missing_count} missing artifacts written to: ${missing_file}"
    log "Feed this file into the rescue-local remediation step."
  else
    rm -f "$missing_file"
    log "No missing artifacts detected. Nothing to remediate."
  fi
}

# ---------- Main ----------
log "=== Upstream check ==="
log "Source repo: ${sourceRepo}"

upstream_base=$(get_upstream_url)

if [[ -n "$fromFile" ]]; then
  [[ ! -r "$fromFile" ]] && { log "ERROR: cannot read ${fromFile}"; exit 1; }
  log "Input: file ${fromFile}"
  input_list="$fromFile"
else
  log "Input: AQL against ${sourceRepo}"
  write_spec
  run_search
  input_list="$out_list"
fi

check_all "$input_list" "$upstream_base"
log "=== Done ==="