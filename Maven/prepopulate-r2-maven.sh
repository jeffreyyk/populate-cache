#!/usr/bin/env bash
#
# prepopulate-r2-maven.sh
# ------------------------------------------------------------------
# Purpose:
#   Maven analog of prepopulate-r2.sh. Two subcommands:
#     1. list        - Enumerate .jar artifacts in R1's cache via AQL
#                      and emit groupId:artifactId:version coordinates.
#     2. prepopulate - Curl HEAD each artifact's .jar and .pom through
#                      R2, so R2 fetches both from upstream, evaluates
#                      Curation, and caches. Optionally also warm
#                      maven-metadata.xml at the artifact level.
#
# Why curl (not jf mvn):
#   Maven doesn't have a separate "metadata endpoint" like npm's
#   /api/npm/<repo>/<pkg>. All Maven metadata is regular files
#   (maven-metadata.xml, .pom, .jar.sha1) served at deterministic
#   URLs. So a direct HEAD through R2 warms the cache correctly —
#   no protocol handler to trip.
#
#   This avoids the Maven CLI + ~/.m2/settings.xml setup that
#   'jf mvn' would require, and doesn't over-populate with
#   transitive dependencies.
#
# Usage:
#   ./prepopulate-r2-maven.sh list \
#       --serverid <id> --sourceRepo <R1> \
#       [--downloadedWithin <dur>] [--createdWithin <dur>] \
#       [--includeSources] [--includeJavadoc]
#
#   ./prepopulate-r2-maven.sh prepopulate \
#       --serverid <id> --targetRepo <R2> \
#       ( --sourceRepo <R1> [--downloadedWithin <dur>] [--createdWithin <dur>] \
#       | --fromFile <PATH> ) \
#       [--withMetadata] [--dry-run] [--connect-timeout <sec>]
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
includeSources="false"
includeJavadoc="false"
withMetadata="false"
dryrun="false"
verbose="false"
connect_timeout="10"
spec_file="maven-spec-$$.json"
out_list="maven-artifacts-$$.txt"
report_csv=""

# ---------- Utility ----------
log() { echo "[$(date '+%H:%M:%S')] $*"; }

usage() {
  cat <<EOF
Usage:
  $0 list --serverid <id> --sourceRepo <R1>
     [--downloadedWithin <dur>] [--createdWithin <dur>]
     [--includeSources] [--includeJavadoc]

  $0 prepopulate --serverid <id> --targetRepo <R2>
     ( --sourceRepo <R1> [--downloadedWithin <dur>] [--createdWithin <dur>]
     | --fromFile <PATH> )
     [--withMetadata] [--dry-run] [--connect-timeout <sec>]

Flags:
  --serverid <id>          JFrog CLI server ID.
  --sourceRepo <R1>        Maven remote whose cache we enumerate.
  --targetRepo <R2>        Maven remote to warm.
  --fromFile <PATH>        Read coord list from a file (one 'groupId:artifactId:version' per line).
  --downloadedWithin <dur> AQL filter: stat.downloaded within duration (e.g. 1y).
  --createdWithin <dur>    AQL filter: created within duration.
  --includeSources         (list only) Also emit *-sources.jar entries. Default: skip.
  --includeJavadoc         (list only) Also emit *-javadoc.jar entries. Default: skip.
  --withMetadata           (prepopulate only) Also warm maven-metadata.xml at the artifact level.
  --dry-run                Print HEAD URLs, do not execute.
  --connect-timeout <sec>  TCP+TLS connect timeout. Default 10s.
  --verbose, -v            Print per-file curl timing (dns/tls/ttfb/total)
                           so cold-cache fetch phases can be diagnosed.

Coordinate format:
  groupId:artifactId:version              -> regular artifact (jar + pom)
  groupId:artifactId:version:pom          -> POM-only artifact (BOM, parent pom)
    e.g. com.google.guava:guava:31.1-jre
         org.apache.cassandra:java-driver-bom:4.19.2:pom

Examples:
  $0 list --serverid sum2 --sourceRepo maven-remote --downloadedWithin 1y
  $0 prepopulate --serverid sum2 --targetRepo maven-remote2 --fromFile coords.txt --withMetadata
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
    --includeSources)    includeSources="true"; shift ;;
    --includeJavadoc)    includeJavadoc="true"; shift ;;
    --withMetadata)      withMetadata="true"; shift ;;
    --dry-run)           dryrun="true"; shift ;;
    --connect-timeout)   connect_timeout="$2"; shift 2 ;;
    --verbose|-v)        verbose="true"; shift ;;
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

# ---------- Config export (for direct curl to R2) ----------
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

if [[ -n "$JF_TOKEN" ]]; then
  AUTH_ARG=(-H "Authorization: Bearer ${JF_TOKEN}")
elif [[ -n "$JF_USER" && -n "$JF_PASS" ]]; then
  AUTH_ARG=(-u "${JF_USER}:${JF_PASS}")
else
  log "ERROR: no credentials found in server config"
  exit 1
fi

[[ "$JF_URL" != */artifactory ]] && JF_URL="${JF_URL}/artifactory"

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

  # Match .jar OR .pom. Regular artifacts have both — we'll dedupe and
  # emit them as "g:a:v" (implicit jar+pom fetching). POM-only artifacts
  # (BOMs, parents) have only .pom — we emit those as "g:a:v:pom" so
  # prepopulate knows not to try fetching a non-existent .jar.
  conditions+=", { \"\$or\": ["
  conditions+=" { \"name\": { \"\$match\": \"*.jar\" } }"
  conditions+=", { \"name\": { \"\$match\": \"*.pom\" } }"
  conditions+=" ] }"

  # Skip sources/javadoc unless explicitly included
  [[ "$includeSources" != "true" ]] && conditions+=", { \"name\": { \"\$nmatch\": \"*-sources.jar\" } }"
  [[ "$includeJavadoc" != "true" ]] && conditions+=", { \"name\": { \"\$nmatch\": \"*-javadoc.jar\" } }"

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

# Convert AQL result to Maven coord.
#
# Path structure in <repo>-cache:
#   <groupId-with-slashes>/<artifactId>/<version>/<artifactId>-<version>.(jar|pom)
#
# Regular artifact (has .jar):    emit "groupId:artifactId:version"
#   -> prepopulate warms both .jar and .pom
# POM-only artifact (BOM/parent): emit "groupId:artifactId:version:pom"
#   -> prepopulate warms only .pom, skips the non-existent .jar
#
# Algorithm:
#   1. For each file, extract (gav, ext) tuple.
#   2. Group by gav.
#   3. If any file for a gav has ext=jar, emit "gav" (regular).
#      Else emit "gav:pom" (POM-only).
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
  local count total_pom
  count=$(awk 'END{print NR}' "$out_list")
  total_pom=$(awk '/:pom$/{c++} END{print c+0}' "$out_list")
  local jar_only=$((count - total_pom))
  log "Found ${count} Maven coordinates: ${jar_only} regular, ${total_pom} POM-only. List: ${out_list}"
}

# ---------- Curl operations ----------

# Convert coord "g:a:v" or "g:a:v:pom" to path segments.
# Emits one "type|path" line per file to fetch.
#
# Regular coord (3 parts):     jar + pom + (metadata if --withMetadata)
# POM-only coord (4 parts):    pom       + (metadata if --withMetadata)
coord_to_paths() {
  local coord="$1"

  # Split coord by ':'
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
    packaging=""       # empty = default (jar+pom)
  fi

  local groupPath
  groupPath=$(echo "$groupId" | tr '.' '/')
  local base="${groupPath}/${artifactId}/${version}/${artifactId}-${version}"
  local metadata="${groupPath}/${artifactId}/maven-metadata.xml"

  # Always emit .pom (both regular and POM-only artifacts have it)
  echo "pom|${base}.pom"
  # Emit .jar unless coord explicitly said POM-only
  if [[ "$packaging" != "pom" ]]; then
    echo "jar|${base}.jar"
  fi
  # metadata is optional per --withMetadata; emit here and caller filters
  echo "metadata|${metadata}"
}

# HEAD one URL through R2. Returns "status|curl_err|timing_detail" (timing is empty unless verbose).
# Uses -I (not -X HEAD) so curl closes cleanly after headers even when
# the server sends a Content-Length that would otherwise make curl wait
# for a body that never arrives.
head_one() {
  local url="$1"
  local curl_err_file="/tmp/prepop_maven_curl_err.$$"

  # Include timing fields only when verbose, to keep the output stream compact otherwise
  local wfmt="%{http_code}"
  [[ "$verbose" == "true" ]] && wfmt="%{http_code}|||dns=%{time_namelookup} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total}"

  local raw="" rc=0
  if raw=$(curl -sSI -o /dev/null -w "$wfmt" \
                "${AUTH_ARG[@]}" \
                --connect-timeout "${connect_timeout}" \
                "${url}" 2>"$curl_err_file"); then
    rc=0
  else
    rc=$?
  fi

  # Split status from timing (delimiter '|||' to avoid collision with the outer '|' delimiter)
  local status="${raw%%|||*}"
  local timing_detail=""
  [[ "$verbose" == "true" && "$raw" == *"|||"* ]] && timing_detail="${raw#*|||}"

  local curl_err=""
  if [[ $rc -ne 0 ]]; then
    curl_err=$(tr '\n' ' ' < "$curl_err_file")
    [[ -z "$status" || ! "$status" =~ ^[0-9]{3}$ ]] && status="000"
  fi
  rm -f "$curl_err_file"
  echo "${status}|${curl_err}|${timing_detail}"
}

# Warm all applicable files for one coord.
prepopulate_one() {
  local coord="$1"

  # Detect if this is a POM-only coord (for display only)
  local pom_only="false"
  [[ "$coord" == *":pom" ]] && pom_only="true"

  # Get files to fetch
  local -a artifacts=()
  while IFS= read -r line; do
    artifacts+=("$line")
  done < <(coord_to_paths "$coord")

  if [[ "$dryrun" == "true" ]]; then
    for artifact in "${artifacts[@]}"; do
      local type_="${artifact%%|*}"
      local path_="${artifact#*|}"
      # Skip metadata unless --withMetadata
      [[ "$type_" == "metadata" && "$withMetadata" != "true" ]] && continue
      local url="${JF_URL}/${targetRepo}/${path_}"
      log "  DRY   HEAD ${url}"
      echo "${coord},${type_},DRY" >> "$report_csv"
    done
    return
  fi

  local display="${coord}"
  [[ "$pom_only" == "true" ]] && display="${coord} (POM-only)"
  printf "[%s]   ...   %s" "$(date '+%H:%M:%S')" "${display}"

  # HEAD each applicable file
  local overall="200"
  local status_line=""
  for artifact in "${artifacts[@]}"; do
    local type_="${artifact%%|*}"
    local path_="${artifact#*|}"
    # Skip metadata unless --withMetadata
    [[ "$type_" == "metadata" && "$withMetadata" != "true" ]] && continue

    local url="${JF_URL}/${targetRepo}/${path_}"
    local result status timing_detail
    result=$(head_one "$url")
    # result format: status|curl_err|timing_detail
    status="${result%%|*}"
    # extract timing after second '|'
    timing_detail="${result#*|}"    # strip status
    timing_detail="${timing_detail#*|}"    # strip curl_err

    status_line+="${type_}=${status} "

    # Roll up worst status
    case "$status" in
      000)                          overall="FAIL" ;;
      403) [[ "$overall" != "FAIL" ]] && overall="403" ;;
      404) [[ "$overall" == "200" ]] && overall="404" ;;
    esac

    echo "${coord},${type_},${status}" >> "$report_csv"

    # When verbose, print the timing detail for this specific file
    [[ -n "$timing_detail" ]] && log "         ${type_} ${status}: ${timing_detail}"
  done

  status_line="${status_line% }"    # trim trailing space

  printf "\r[%s]   " "$(date '+%H:%M:%S')"
  case "$overall" in
    200)  printf "OK    [200]  %s  (%s)\n" "${display}" "${status_line}" ;;
    403)  printf "BLOCK [403]  %s  (%s)  (Curation denied)\n" "${display}" "${status_line}" ;;
    404)  printf "MISS  [404]  %s  (%s)  (not in upstream)\n" "${display}" "${status_line}" ;;
    FAIL) printf "FAIL  [---]  %s  (%s)\n" "${display}" "${status_line}" ;;
  esac
}

prepopulate_all() {
  local input_list="$1"
  report_csv="maven-prepop-report-${targetRepo}-$(date +%Y%m%d-%H%M%S).csv"
  echo "coord,artifact_type,http_status" > "$report_csv"

  [[ "$dryrun" == "true" ]] && log "DRY RUN - no requests will hit R2"
  log "Pre-populating ${targetRepo} via curl HEAD (.jar + .pom${withMetadata:+ + maven-metadata.xml})..."

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

  log "Complete. ${count} coordinates processed. Report: ${report_csv}"
  log "Summary (by artifact_type + status):"
  awk -F',' 'NR>1 {c[$2"/"$3]++} END {for (k in c) printf "  %-15s : %d\n", k, c[k]}' \
    "$report_csv" | sort
}

# ---------- Subcommands ----------
cmd_list() {
  [[ -z "$sourceRepo" ]] && { log "ERROR: --sourceRepo required"; usage; }
  log "=== List mode (maven) ==="
  log "Source: ${sourceRepo}"
  log "Include sources: ${includeSources}   javadoc: ${includeJavadoc}"
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

  log "=== Prepopulate mode (maven) ==="
  log "Target: ${targetRepo}"
  log "With metadata: ${withMetadata}"
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