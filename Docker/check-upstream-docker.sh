#!/usr/bin/env bash
#
# check-upstream-docker.sh
# ------------------------------------------------------------------
# Purpose:
#   Given a list of Docker image:tag refs, HEAD each one directly
#   against the upstream registry (DockerHub, GHCR, private Nexus,
#   whatever R1 was configured to proxy) to determine whether the
#   image still exists upstream.
#
#   R1's config is used only to discover the upstream URL — the
#   actual check goes straight to upstream, so R1's cache state is
#   irrelevant to the answer.
#
#   Emits:
#     - Full CSV report: image, tag, status
#     - Missing-only text file: image:tag entries that came back 404
#       (input to the rescue-local remediation step).
#
# Upstream auth handling:
#   1. If --upstreamAuthToken is given, use it as a static Bearer.
#   2. Else if --upstreamUser/--upstreamPassword are given, use Basic.
#   3. Else try anonymous, then follow the standard Docker Registry v2
#      bearer challenge flow when the upstream responds 401 with a
#      Www-Authenticate header. This handles DockerHub public images,
#      GHCR public, Quay public, etc. without extra config.
#
# Coordinate format (matches prepopulate-r2-docker.sh output):
#   image:tag                        - regular tag
#   image:tag#os/arch                - platform-scoped (the '#os/arch'
#                                      suffix is stripped; upstream
#                                      manifest API is tag-based)
#
# Usage:
#   ./check-upstream-docker.sh --serverid <id> --sourceRepo <repo>
#       ( --fromFile <path>
#       | [--createdWithin <dur>] )
#       [--upstreamUser <u> --upstreamPassword <p>]
#       [--upstreamAuthToken <t>]
#       [--connect-timeout <sec>] [--verbose]
# ------------------------------------------------------------------

set -euo pipefail

# ---------- Defaults ----------
serverid=""
sourceRepo=""
fromFile=""
createdWithin=""
upstreamUser=""
upstreamPassword=""
upstreamAuthToken=""
viaR1="false"
connect_timeout="10"
verbose="false"
spec_file="check-docker-spec-$$.json"
out_list="check-docker-list-$$.txt"
report_csv=""

# ---------- Utility ----------
log() { echo "[$(date '+%H:%M:%S')] $*"; }

usage() {
  cat <<EOF
Usage:
  $0 --serverid <id> --sourceRepo <repo>
     ( --fromFile <path>
     | [--createdWithin <dur>] )
     [--upstreamUser <u> --upstreamPassword <p>]
     [--upstreamAuthToken <t>]
     [--connect-timeout <sec>] [--verbose]

Flags:
  --serverid <id>          JFrog CLI server ID (only used to read R1's config).
  --sourceRepo <repo>      Docker remote whose upstream URL we resolve.
  --fromFile <path>        Read image:tag list from a file (one per line).
                           Optional '#os/arch' suffix is stripped.
  --createdWithin <dur>    AQL filter on 'created' when auto-enumerating from R1.

  --upstreamUser <u>       Optional. Upstream registry username for Basic auth.
  --upstreamPassword <p>   Optional. Upstream registry password for Basic auth.
  --upstreamAuthToken <t>  Optional. Pre-obtained Bearer token for upstream.
                           Overrides user/password if both are given.

  --via-r1                 Route checks through your Artifactory tenant's
                           Docker Registry API instead of hitting upstream
                           directly. Useful when corporate proxies (Zscaler,
                           egress firewalls) block direct DockerHub access
                           but allow server-to-registry traffic from your
                           Artifactory instance.

  --connect-timeout <sec>  TCP+TLS connect timeout. Default 10s.
  --verbose, -v            Print per-image curl timing (dns/tls/ttfb/total).

Examples:
  # Public images on DockerHub — anonymous with bearer challenge
  $0 --serverid psblr --sourceRepo bmc-docker-remote --fromFile docker-tags.txt

  # Private upstream with basic auth
  $0 --serverid psblr --sourceRepo bmc-docker-remote --fromFile docker-tags.txt \\
    --upstreamUser myuser --upstreamPassword mypass
EOF
  exit 1
}

# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --serverid)             serverid="$2"; shift 2 ;;
    --sourceRepo)           sourceRepo="$2"; shift 2 ;;
    --fromFile)             fromFile="$2"; shift 2 ;;
    --createdWithin)        createdWithin="$2"; shift 2 ;;
    --upstreamUser)         upstreamUser="$2"; shift 2 ;;
    --upstreamPassword)     upstreamPassword="$2"; shift 2 ;;
    --upstreamAuthToken)    upstreamAuthToken="$2"; shift 2 ;;
    --via-r1)               viaR1="true"; shift ;;
    --connect-timeout)      connect_timeout="$2"; shift 2 ;;
    --verbose|-v)           verbose="true"; shift ;;
    --help|-h)              usage ;;
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
# For direct-upstream mode we don't need Artifactory credentials, but
# --via-r1 routes checks through the tenant's Docker Registry endpoint
# and needs an auth header. We always export so a runtime flip to
# --via-r1 works without a second setup step.
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
# Ask R1 for its config, extract the upstream URL. That's all we
# need from R1 — the actual checks bypass R1 entirely.
get_upstream_url() {
  local url
  url=$(jf rt curl -X GET "/api/repositories/${sourceRepo}" --server-id="$serverid" 2>/dev/null \
        | jq -r '.url // empty' | sed 's|/$||')
  if [[ -z "$url" ]]; then
    log "ERROR: could not read upstream URL from ${sourceRepo}'s config."
    log "       (is it a remote repo? does the token have read access?)"
    exit 1
  fi
  # DockerHub cosmetic: index.docker.io is the "docs" host, registry-1.docker.io
  # is the actual v2 API host. Normalize.
  url="${url/https:\/\/index.docker.io/https://registry-1.docker.io}"
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
  conditions+=" { \"name\": { \"\$eq\": \"manifest.json\" } }"
  conditions+=", { \"name\": { \"\$eq\": \"list.manifest.json\" } }"
  conditions+=" ] }"
  conditions+=", { \"path\": { \"\$nmatch\": \"*sha256__*\" } }"
  conditions+=", { \"path\": { \"\$nmatch\": \".jfrog*\" } }"

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
  log "Searching ${sourceRepo}-cache for tag folders..."
  jf rt s --spec="$spec_file" --server-id="$serverid" \
    | jq -r --arg prefix "${sourceRepo}-cache/" '
        .[] | .path
        | sub("^" + $prefix; "")
        | sub("/(list\\.)?manifest\\.json$"; "")
        | capture("(?<image>.+)/(?<tag>[^/]+)$")
        | "\(.image):\(.tag)"
      ' \
    | sort -u \
    > "$out_list"
  local count
  count=$(awk 'END{print NR}' "$out_list")
  log "Found ${count} unique image:tag entries. List: ${out_list}"
}

# ---------- Bearer challenge handling ----------
# Parse a Www-Authenticate header of the form:
#   Bearer realm="https://...",service="registry.example.com",scope="..."
# and return the token URL. Prints to stdout.
parse_bearer_challenge() {
  local hdr="$1"
  local image="$2"
  local realm service
  realm=$(echo "$hdr" | sed -n 's/.*realm="\([^"]*\)".*/\1/p')
  service=$(echo "$hdr" | sed -n 's/.*service="\([^"]*\)".*/\1/p')
  [[ -z "$realm" ]] && { echo ""; return; }

  local scope="repository:${image}:pull"
  # Build URL; service is optional per spec but commonly required
  if [[ -n "$service" ]]; then
    echo "${realm}?service=${service}&scope=${scope}"
  else
    echo "${realm}?scope=${scope}"
  fi
}

# Fetch a Bearer token from the challenge URL. Uses upstream Basic
# auth on the token endpoint if credentials are provided (needed for
# private DockerHub repos etc). Prints token to stdout, empty on failure.
fetch_bearer_token() {
  local token_url="$1"
  local -a auth=()
  if [[ -n "$upstreamUser" ]]; then
    auth=(-u "${upstreamUser}:${upstreamPassword}")
  fi
  curl -sS ${auth[@]+"${auth[@]}"} --connect-timeout "$connect_timeout" "$token_url" 2>/dev/null \
    | jq -r '.token // .access_token // empty'
}

# ---------- Upstream check (per image:tag) ----------
UPSTREAM_URL=""
ACCEPT_HDR="Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json"

check_one() {
  local input_line="$1"

  # Strip optional #platform suffix
  local ref="${input_line%%#*}"
  local image="${ref%:*}"
  local tag="${ref##*:}"

  local url
  local -a curl_auth=()
  if [[ "$viaR1" == "true" ]]; then
    # Route through your Artifactory tenant's Docker Registry API. R1 will
    # serve from its cache if fresh, or (when configured to) contact upstream
    # to refresh. In corporate environments where direct upstream is blocked
    # (Zscaler category filters, egress firewalls), this is the only path
    # that reaches DockerHub/etc.
    url="${JF_URL}/api/docker/${sourceRepo}/v2/${image}/manifests/${tag}"
    curl_auth=("${R1_AUTH[@]}")
  else
    url="${UPSTREAM_URL}/v2/${image}/manifests/${tag}"
    if [[ -n "$upstreamAuthToken" ]]; then
      curl_auth=(-H "Authorization: Bearer ${upstreamAuthToken}")
    elif [[ -n "$upstreamUser" ]]; then
      curl_auth=(-u "${upstreamUser}:${upstreamPassword}")
    fi
  fi

  # Timing format
  local wfmt="%{http_code}"
  [[ "$verbose" == "true" ]] && wfmt="%{http_code}|||dns=%{time_namelookup} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total}"

  local headers_file
  headers_file=$(mktemp)

  local raw="" rc=0
  if raw=$(curl -sSI -D "$headers_file" -o /dev/null -w "$wfmt" \
                ${curl_auth[@]+"${curl_auth[@]}"} \
                -H "$ACCEPT_HDR" \
                --connect-timeout "$connect_timeout" \
                -L \
                "$url" 2>/dev/null); then
    rc=0
  else
    rc=$?
  fi

  local status="${raw%%|||*}"
  local timing_detail=""
  [[ "$verbose" == "true" && "$raw" == *"|||"* ]] && timing_detail="${raw#*|||}"

  [[ -z "$status" || ! "$status" =~ ^[0-9]{3}$ ]] && status="000"

  # If 401, look for a bearer challenge and try again
  # (only meaningful for direct-upstream mode; via-r1 already carries auth)
  if [[ "$status" == "401" && "$viaR1" != "true" ]]; then
    local auth_hdr
    auth_hdr=$(grep -i "^www-authenticate:" "$headers_file" | head -1 | tr -d '\r')
    if [[ "$auth_hdr" == *[Bb]earer* ]]; then
      local token_url
      token_url=$(parse_bearer_challenge "$auth_hdr" "$image")
      if [[ -n "$token_url" ]]; then
        local token
        token=$(fetch_bearer_token "$token_url")
        if [[ -n "$token" ]]; then
          # Retry with the freshly minted token
          if raw=$(curl -sSI -o /dev/null -w "$wfmt" \
                        -H "Authorization: Bearer ${token}" \
                        -H "$ACCEPT_HDR" \
                        --connect-timeout "$connect_timeout" \
                        -L \
                        "$url" 2>/dev/null); then
            status="${raw%%|||*}"
            [[ "$verbose" == "true" && "$raw" == *"|||"* ]] && timing_detail="${raw#*|||}"
          fi
        fi
      fi
    fi
  fi

  rm -f "$headers_file"

  local label suffix=""
  case "$status" in
    200)  label="OK    [200]" ;;
    307|302|301)
          # Redirects to proxy-interception landing pages (Zscaler, corporate
          # web filters). -L follows, but if the final page isn't a manifest,
          # this isn't a real 200 either. Grab the Location target for
          # troubleshooting context.
          local loc
          loc=$(grep -i "^location:" "$headers_file" | head -1 | tr -d '\r' | cut -c11- | head -c 80)
          label="BLOCK [${status}]"
          suffix="  (proxy/filter redirect → ${loc:-unknown})" ;;
    401)  label="AUTH  [401]"; suffix="  (upstream auth failed — check --upstreamUser / --upstreamPassword, or corporate proxy is intercepting)" ;;
    403)  label="AUTH  [403]"; suffix="  (upstream denied)" ;;
    404)  label="MISS  [404]"; suffix="  (missing from upstream)" ;;
    429)  label="RATE  [429]"; suffix="  (upstream rate-limited — wait and retry, or authenticate)" ;;
    000)  label="FAIL  [---]"; suffix="  (network/TLS error)" ;;
    *)    label="?     [${status}]" ;;
  esac

  log "  ${label}  ${ref}${suffix}"
  [[ -n "$timing_detail" ]] && log "         ${timing_detail}"

  echo "${image},${tag},${status}" >> "$report_csv"
}

check_all() {
  local input_list="$1"
  report_csv="upstream-check-docker-${sourceRepo}-$(date +%Y%m%d-%H%M%S).csv"
  echo "image,tag,upstream_status" > "$report_csv"

  if [[ "$viaR1" == "true" ]]; then
    log "Mode: via R1 (${JF_URL}/api/docker/${sourceRepo}/v2/...)"
    log "      R1 will refresh from upstream if cache is stale"
  else
    log "Upstream URL: ${UPSTREAM_URL}"
    if [[ -n "$upstreamAuthToken" ]]; then
      log "Auth: static Bearer token"
    elif [[ -n "$upstreamUser" ]]; then
      log "Auth: basic (${upstreamUser})"
    else
      log "Auth: anonymous (will follow bearer challenge if upstream requires it)"
    fi
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

  log "Complete. ${count} tags checked. Report: ${report_csv}"
  log "Summary (by status):"
  awk -F',' 'NR>1 {c[$3]++} END {for (s in c) printf "  %-8s : %d\n", s, c[s]}' \
    "$report_csv" | sort

  local missing_file="upstream-missing-docker-${sourceRepo}-$(date +%Y%m%d-%H%M%S).txt"
  awk -F',' 'NR>1 && $3 == "404" {print $1":"$2}' "$report_csv" | sort -u > "$missing_file"
  local missing_count
  missing_count=$(awk 'END{print NR}' "$missing_file")
  if [[ $missing_count -gt 0 ]]; then
    log "${missing_count} image(s) missing from upstream: ${missing_file}"
    log "Feed this file into the rescue-local remediation step."
  else
    rm -f "$missing_file"
    log "No missing images detected. Nothing to remediate."
  fi
}

# ---------- Main ----------
log "=== Upstream check (docker) ==="
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