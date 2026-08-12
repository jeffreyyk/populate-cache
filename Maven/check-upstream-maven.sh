#!/usr/bin/env bash
#
# check-upstream-maven.sh
# ------------------------------------------------------------------
# Purpose:
#   Given a list of Maven coordinates (from a file or from AQL against
#   an R1 remote), test each expected file (.jar and/or .pom) against
#   the upstream URL configured on the source remote.
#
#   Emits:
#     - Full CSV report: coord, artifact_type, upstream_status
#     - Missing-only text file: coords where any expected file 404'd
#       (input to the rescue-local remediation step).
#
# Coordinate format (matches prepopulate-r2-maven.sh output):
#   groupId:artifactId:version           -> regular artifact, checks .jar + .pom
#   groupId:artifactId:version:pom       -> POM-only (BOM/parent), checks only .pom
#
# Usage:
#   ./check-upstream-maven.sh --serverid <id> --sourceRepo <repo>
#       ( --fromFile <path>
#       | [--downloadedWithin <dur>] [--createdWithin <dur>] )
#       [--connect-timeout <sec>] [--verbose]
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
spec_file="check-maven-spec-$$.json"
out_list="check-maven-list-$$.txt"
report_csv=""

# ---------- Utility ----------
log() { echo "[$(date '+%H:%M:%S')] $*"; }

usage() {
  cat <<EOF
Usage:
  $0 --serverid <id> --sourceRepo <repo>
     ( --fromFile <path>
     | [--downloadedWithin <dur>] [--createdWithin <dur>] )
     [--connect-timeout <sec>] [--verbose]

Examples:
  # Check a pre-built coord list against the R1 upstream
  $0 --serverid psblr --sourceRepo maven-remote --fromFile maven-artifacts.txt

  # Check everything R1 has cached in the last year
  $0 --serverid psblr --sourceRepo maven-remote --downloadedWithin 1y
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

  # Match .jar OR .pom (same shape as prepopulate-r2-maven.sh)
  conditions+=", { \"\$or\": ["
  conditions+=" { \"name\": { \"\$match\": \"*.jar\" } }"
  conditions+=", { \"name\": { \"\$match\": \"*.pom\" } }"
  conditions+=" ] }"
  # Skip sources/javadoc by default
  conditions+=", { \"name\": { \"\$nmatch\": \"*-sources.jar\" } }"
  conditions+=", { \"name\": { \"\$nmatch\": \"*-javadoc.jar\" } }"

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
  log "Searching ${sourceRepo}-cache for Maven artifacts..."
  jf rt s --spec="$spec_file" --server-id="$serverid" \
    | jq -r --arg prefix "${sourceRepo}-cache/" '
        [
          .[] | .path
          | sub("^" + $prefix; "")
          | capture("(?<pp>.+)/[^/]+\\.(?<ext>jar|pom)$")
          | .pp as $pp
          | ($pp | split("/")) as $parts
          | ($parts | length) as $n
          | select($n >= 2)
          | {
              gav: "\($parts[0:$n-2] | join(".")):\($parts[$n-2]):\($parts[$n-1])",
              ext: .ext
            }
        ]
        | group_by(.gav)
        | .[]
        | . as $group
        | ($group | any(.ext == "jar")) as $has_jar
        | if $has_jar then $group[0].gav else "\($group[0].gav):pom" end
      ' \
    | sort -u \
    > "$out_list"
  local count
  count=$(awk 'END{print NR}' "$out_list")
  log "Found ${count} Maven coordinates. List: ${out_list}"
}

# ---------- Coord -> upstream path list ----------
# Emits "type|relative-path" lines for each file to check upstream.
coord_to_paths() {
  local coord="$1"

  local groupId="${coord%%:*}"
  local rest="${coord#*:}"
  local artifactId="${rest%%:*}"
  rest="${rest#*:}"
  local version packaging
  if [[ "$rest" == *":"* ]]; then
    version="${rest%%:*}"
    packaging="${rest#*:}"
  else
    version="$rest"
    packaging=""
  fi

  local groupPath
  groupPath=$(echo "$groupId" | tr '.' '/')
  local base="${groupPath}/${artifactId}/${version}/${artifactId}-${version}"

  # Always .pom
  echo "pom|${base}.pom"
  # .jar unless coord explicitly said POM-only
  if [[ "$packaging" != "pom" ]]; then
    echo "jar|${base}.jar"
  fi
}

# ---------- Upstream check (per coord) ----------
check_one() {
  local coord="$1"
  local upstream_base="$2"

  local pom_only="false"
  [[ "$coord" == *":pom" ]] && pom_only="true"

  local display="${coord}"
  [[ "$pom_only" == "true" ]] && display="${coord} (POM-only)"

  printf "[%s]   ...   %s" "$(date '+%H:%M:%S')" "${display}"

  # Get list of (type, path) tuples
  local -a artifacts=()
  while IFS= read -r line; do
    artifacts+=("$line")
  done < <(coord_to_paths "$coord")

  # HEAD each expected file at the upstream URL
  local overall="200"
  local status_line=""
  for artifact in "${artifacts[@]}"; do
    local type_="${artifact%%|*}"
    local path_="${artifact#*|}"
    local url="${upstream_base}/${path_}"

    local curl_err_file="/tmp/check_maven_err.$$"
    local status=0 rc=0 timing_fmt="%{http_code}"
    [[ "$verbose" == "true" ]] && timing_fmt="%{http_code}|dns=%{time_namelookup} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total}"

    local raw
    if raw=$(curl -sSLI -o /dev/null -w "$timing_fmt" \
                  --connect-timeout "${connect_timeout}" \
                  "${url}" 2>"$curl_err_file"); then
      rc=0
    else
      rc=$?
    fi
    status="${raw%%|*}"
    local timing_detail=""
    [[ "$verbose" == "true" && "$raw" == *"|"* ]] && timing_detail="${raw#*|}"

    local curl_err=""
    if [[ $rc -ne 0 ]]; then
      curl_err=$(tr '\n' ' ' < "$curl_err_file")
      [[ -z "$status" || ! "$status" =~ ^[0-9]{3}$ ]] && status="000"
    fi
    rm -f "$curl_err_file"

    status_line+="${type_}=${status} "

    # Roll up worst status
    case "$status" in
      000)                          overall="FAIL" ;;
      403|401) [[ "$overall" != "FAIL" ]] && overall="AUTH" ;;
      404) [[ "$overall" == "200" || "$overall" == "AUTH" ]] && overall="404" ;;
    esac

    echo "${coord},${type_},${status}" >> "$report_csv"
    [[ -n "$timing_detail" ]] && log "         ${type_} timing: ${timing_detail}"
  done

  status_line="${status_line% }"

  printf "\r[%s]   " "$(date '+%H:%M:%S')"
  case "$overall" in
    200)  printf "OK    [200]  %s  (%s)\n" "${display}" "${status_line}" ;;
    AUTH) printf "AUTH  [401/403]  %s  (%s)  (upstream requires auth)\n" "${display}" "${status_line}" ;;
    404)  printf "MISS  [404]  %s  (%s)  (missing from upstream)\n" "${display}" "${status_line}" ;;
    FAIL) printf "FAIL  [---]  %s  (%s)\n" "${display}" "${status_line}" ;;
  esac
}

check_all() {
  local input_list="$1"
  local upstream_base="$2"
  report_csv="upstream-check-maven-${sourceRepo}-$(date +%Y%m%d-%H%M%S).csv"
  echo "coord,artifact_type,upstream_status" > "$report_csv"

  log "Upstream base: ${upstream_base}"
  log "Checking coordinates..."

  local count=0
  while IFS= read -r LINE || [[ -n "$LINE" ]]; do
    LINE="${LINE%$'\r'}"
    LINE="${LINE#"${LINE%%[![:space:]]*}"}"
    LINE="${LINE%"${LINE##*[![:space:]]}"}"
    [[ -z "$LINE" ]] && continue
    [[ "$LINE" == \#* ]] && continue
    check_one "$LINE" "$upstream_base"
    count=$((count + 1))
  done < "$input_list"

  log "Complete. ${count} coordinates checked. Report: ${report_csv}"
  log "Summary (by artifact_type + status):"
  awk -F',' 'NR>1 {c[$2"/"$3]++} END {for (k in c) printf "  %-15s : %d\n", k, c[k]}' \
    "$report_csv" | sort

  # Extract coords with ANY 404 file → missing list for rescue-local
  local missing_file="upstream-missing-maven-${sourceRepo}-$(date +%Y%m%d-%H%M%S).txt"
  awk -F',' 'NR>1 && $3 == "404" {print $1}' "$report_csv" | sort -u > "$missing_file"
  local missing_count
  missing_count=$(awk 'END{print NR}' "$missing_file")
  if [[ $missing_count -gt 0 ]]; then
    log "${missing_count} coordinate(s) with at least one 404 file: ${missing_file}"
    log "Feed this file into the rescue-local remediation step."
  else
    rm -f "$missing_file"
    log "No missing artifacts detected. Nothing to remediate."
  fi
}

# ---------- Main ----------
log "=== Upstream check (maven) ==="
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
