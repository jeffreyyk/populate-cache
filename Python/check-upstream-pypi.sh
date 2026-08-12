#!/usr/bin/env bash
#
# check-upstream-pypi.sh
# ------------------------------------------------------------------
# Purpose:
#   Given a list of pkg==version pairs (from a file or from AQL against
#   an R1 remote), test each one directly against the upstream PyPI
#   simple index (pypi.org by default, or whichever URL R1 is proxying).
#
#   Emits:
#     - Full CSV report: pkg, version, upstream_status
#     - Missing-only text file: pkg==version entries that came back
#       404 or where the specific version wasn't in the simple index
#       (input to the rescue-local remediation step).
#
# How it checks:
#   1. GET <upstream>/simple/<normalized-pkg>/
#      PEP 503 index — one HTML page per package listing all files.
#   2. If 200, grep the response body for '<pkg>-<version>-' (wheels)
#      or '<pkg>-<version>.' (sdists/zips). Match = version exists.
#   3. If 404 on the simple page, the whole package is gone.
#
# Package name normalization (PEP 503):
#   Lowercase, and runs of '-', '_', '.' collapse to a single '-'.
#   e.g. python_dateutil -> python-dateutil
#        Django          -> django
#        zope.interface  -> zope-interface
#
# Usage:
#   ./check-upstream-pypi.sh --serverid <id> --sourceRepo <repo>
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
viaR1="false"
connect_timeout="10"
verbose="false"
spec_file="check-pypi-spec-$$.json"
out_list="check-pypi-list-$$.txt"
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
  # Direct upstream (works when no corporate proxy is intercepting)
  $0 --serverid psblr --sourceRepo pypi-remote --fromFile pypi-artifacts.txt

  # Route through R1's tenant (works around corporate proxies like Zscaler
  # that block direct pypi.org / files.pythonhosted.org from client machines)
  $0 --serverid psblr --sourceRepo pypi-remote --fromFile pypi-artifacts.txt --via-r1

Flags:
  --via-r1               Route the simple-index checks through your Artifactory
                         tenant's PyPI API instead of hitting upstream directly.
                         Use this when corporate proxies block outbound access to
                         pypi.org or files.pythonhosted.org.
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
    --via-r1)            viaR1="true"; shift ;;
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

# ---------- Config export (needed for --via-r1 mode) ----------
server_json=$(jf c export "$serverid" 2>/dev/null | base64 --decode 2>/dev/null || true)
if [[ -z "$server_json" ]]; then
  log "ERROR: could not export server config for '$serverid'"
  exit 1
fi
JF_URL=$(echo "$server_json" | jq -r '.url // .artifactoryUrl // empty' | sed 's|/$||')
JF_TOKEN=$(echo "$server_json" | jq -r '.accessToken // empty')
JF_USER=$(echo "$server_json" | jq -r '.user // empty')
JF_PASS=$(echo "$server_json" | jq -r '.password // empty')
[[ -z "$JF_URL" ]] && { log "ERROR: could not parse artifactory URL"; exit 1; }
[[ "$JF_URL" != */artifactory ]] && JF_URL="${JF_URL}/artifactory"

R1_AUTH=()
if [[ -n "$JF_TOKEN" ]]; then
  R1_AUTH=(-H "Authorization: Bearer ${JF_TOKEN}")
elif [[ -n "$JF_USER" && -n "$JF_PASS" ]]; then
  R1_AUTH=(-u "${JF_USER}:${JF_PASS}")
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

  # files.pythonhosted.org is PyPI's CDN for artifact bytes only —
  # it doesn't serve the simple index. If R1 is configured to point
  # there directly (a common misconfig or DIY optimization), swap
  # to pypi.org which is the canonical index host.
  case "$url" in
    *files.pythonhosted.org*)
      log "  Note: R1 upstream is files.pythonhosted.org (CDN, not index)."
      log "        Using https://pypi.org for the simple-index check instead."
      url="https://pypi.org"
      ;;
  esac

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

# ---------- PEP 503 name normalization ----------
# Lowercase, and any run of '-', '_', '.' collapses to a single '-'.
normalize_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[-_.]+/-/g'
}

# ---------- Upstream check (per pkg) ----------
UPSTREAM_URL=""

check_one() {
  local pkgver="$1"
  local pkg="${pkgver%%==*}"
  local version="${pkgver#*==}"

  local norm_pkg
  norm_pkg=$(normalize_name "$pkg")

  local url
  local -a curl_auth=()
  if [[ "$viaR1" == "true" ]]; then
    # Route through your Artifactory tenant's PyPI API. R1 will serve
    # the simple index either from cache or by proxying upstream. This
    # is the only workable path when direct-upstream is blocked by a
    # corporate proxy (Zscaler etc).
    url="${JF_URL}/api/pypi/${sourceRepo}/simple/${norm_pkg}/"
    curl_auth=("${R1_AUTH[@]}")
  else
    url="${UPSTREAM_URL}/simple/${norm_pkg}/"
  fi

  # Timing format
  local wfmt="%{http_code}"
  [[ "$verbose" == "true" ]] && wfmt="%{http_code}|||dns=%{time_namelookup} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total}"

  local response_file
  response_file=$(mktemp)
  local curl_err_file="/tmp/check_pypi_err.$$"

  local raw="" rc=0
  if raw=$(curl -sSL -o "$response_file" -w "$wfmt" \
                ${curl_auth[@]+"${curl_auth[@]}"} \
                --connect-timeout "$connect_timeout" \
                "$url" 2>"$curl_err_file"); then
    rc=0
  else
    rc=$?
  fi

  local status="${raw%%|||*}"
  local timing_detail=""
  [[ "$verbose" == "true" && "$raw" == *"|||"* ]] && timing_detail="${raw#*|||}"

  [[ -z "$status" || ! "$status" =~ ^[0-9]{3}$ ]] && status="000"

  local curl_err=""
  if [[ $rc -ne 0 ]]; then
    curl_err=$(tr '\n' ' ' < "$curl_err_file")
  fi
  rm -f "$curl_err_file"

  local result
  if [[ "$status" == "200" ]]; then
    # Simple page exists — grep for this specific version.
    # Wheels have filenames like <name>-<version>-<py>-<abi>-<platform>.whl
    #   → substring "<name>-<version>-"
    # Sdists have <name>-<version>.tar.gz / .zip
    #   → substring "<name>-<version>."
    if grep -qF -e "${norm_pkg}-${version}-" -e "${norm_pkg}-${version}." "$response_file"; then
      result="OK"
    else
      result="MISS_VER"    # pkg exists upstream but this specific version is yanked/gone
    fi
  elif [[ "$status" == "404" ]]; then
    result="MISS_PKG"      # whole package gone from upstream
  elif [[ "$status" == "401" || "$status" == "403" ]]; then
    result="AUTH"          # corporate proxy, private index requiring auth, or similar
  elif [[ "$status" == "000" ]]; then
    result="FAIL"
  else
    result="OTHER"
  fi

  rm -f "$response_file"

  local label suffix=""
  case "$result" in
    OK)       label="OK    [200]" ;;
    MISS_PKG) label="MISS  [404]"; suffix="  (package not in upstream)" ;;
    MISS_VER) label="MISS  [200/yanked]"; suffix="  (upstream has ${norm_pkg} but not version ${version})" ;;
    AUTH)     label="AUTH  [${status}]"
              if [[ "$viaR1" == "true" ]]; then
                suffix="  (tenant returned ${status} — check server-id auth)"
              else
                suffix="  (upstream returned ${status} — likely corporate proxy interception; try --via-r1)"
              fi ;;
    FAIL)     label="FAIL  [---]"; suffix="  (${curl_err})" ;;
    OTHER)    label="?     [${status}]"; suffix="  (unexpected)" ;;
  esac

  log "  ${label}  ${pkgver}${suffix}"
  [[ -n "$timing_detail" ]] && log "         ${timing_detail}"

  # In CSV, both MISS_PKG and MISS_VER report as "404" so downstream
  # rescue-local flow only needs to filter one status; the label
  # above makes the distinction visible on the console.
  local csv_status="$status"
  [[ "$result" == "MISS_VER" ]] && csv_status="404"

  echo "${pkg},${version},${csv_status}" >> "$report_csv"
}

check_all() {
  local input_list="$1"
  report_csv="upstream-check-pypi-${sourceRepo}-$(date +%Y%m%d-%H%M%S).csv"
  echo "pkg,version,upstream_status" > "$report_csv"

  if [[ "$viaR1" == "true" ]]; then
    log "Mode: via R1 (${JF_URL}/api/pypi/${sourceRepo}/simple/...)"
    log "      Uses tenant credentials; index is served by Artifactory."
  else
    log "Upstream: ${UPSTREAM_URL}"
    log "Mode: direct upstream"
  fi
  log "Checking..."

  local count=0
  while IFS= read -r LINE || [[ -n "$LINE" ]]; do
    LINE="${LINE%$'\r'}"
    LINE="${LINE#"${LINE%%[![:space:]]*}"}"
    LINE="${LINE%"${LINE##*[![:space:]]}"}"
    [[ -z "$LINE" ]] && continue
    [[ "$LINE" == \#* ]] && continue
    check_one "$LINE"
    count=$((count + 1))
  done < "$input_list"

  log "Complete. ${count} pkg==version entries checked. Report: ${report_csv}"
  log "Summary (by status):"
  awk -F',' 'NR>1 {c[$3]++} END {for (s in c) printf "  %-8s : %d\n", s, c[s]}' \
    "$report_csv" | sort

  local missing_file="upstream-missing-pypi-${sourceRepo}-$(date +%Y%m%d-%H%M%S).txt"
  awk -F',' 'NR>1 && $3 == "404" {print $1"=="$2}' "$report_csv" | sort -u > "$missing_file"
  local missing_count
  missing_count=$(awk 'END{print NR}' "$missing_file")
  if [[ $missing_count -gt 0 ]]; then
    log "${missing_count} pkg==version entries missing from upstream: ${missing_file}"
    log "Feed this file into the rescue-local remediation step."
  else
    rm -f "$missing_file"
    log "No missing packages detected. Nothing to remediate."
  fi
}

# ---------- Main ----------
log "=== Upstream check (pypi) ==="
log "Source repo: ${sourceRepo}"

UPSTREAM_URL=""
if [[ "$viaR1" != "true" ]]; then
  UPSTREAM_URL=$(get_upstream_url)
fi

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

check_all "$input_list"
log "=== Done ==="