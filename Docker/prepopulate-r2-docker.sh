#!/usr/bin/env bash
#
# prepopulate-r2-docker.sh
# ------------------------------------------------------------------
# Purpose:
#   Docker analog of prepopulate-r2.sh. Two modes:
#     1. list        - Enumerate tag folders in R1's cache. For each
#                      tag, fetch the fat manifest, cross-reference
#                      with cached digest folders in R1, and emit
#                      one 'image:tag#os/arch' per cached architecture.
#                      Single-arch tags emit as 'image:tag' (no #).
#                      Attestations and non-image manifest entries
#                      are skipped.
#     2. prepopulate - `jf docker pull --platform=<os/arch>` each ref
#                      through R2 to warm R2's cache with the exact
#                      arches R1 had. Warms the fat manifest along
#                      the way (implicit in a tag-based pull).
#
# Why this design:
#   - Digest-only pulls (image@sha256:...) can hit attestations and
#     other non-image manifests that docker pull can't parse.
#   - Digest-only pulls also skip the fat manifest, leaving R2 without
#     a tag->digest mapping.
#   - Pulling by tag with --platform hits both the fat manifest AND
#     the correct arch manifest, matches R1's arch coverage exactly,
#     and naturally skips attestations.
#
# Requirements:
#   - Working `docker` daemon (jf docker pull shells out to real docker).
#   - jf CLI configured with a server ID (handles registry auth via
#     --server-id; no manual 'docker login' needed).
#
# Usage:
#   ./prepopulate-r2-docker.sh list \
#       --serverid <id> --sourceRepo <R1>
#       [--createdWithin <dur>]
#
#   ./prepopulate-r2-docker.sh prepopulate \
#       --serverid <id> --targetRepo <R2>
#       ( --sourceRepo <R1> [--createdWithin <dur>]
#       | --fromFile <PATH> )
#       [--registryHost <host>] [--keep-local] [--dry-run]
# ------------------------------------------------------------------

set -euo pipefail

# ---------- Defaults ----------
serverid=""
sourceRepo=""
targetRepo=""
createdWithin=""
fromFile=""
registryHost=""
keep_local="false"
dryrun="false"
verbose="false"
spec_file="docker-spec-$$.json"
out_list="docker-tags-$$.txt"
report_csv=""

# ---------- Utility ----------
log() { echo "[$(date '+%H:%M:%S')] $*"; }

usage() {
  cat <<EOF
Usage:
  $0 list --serverid <id> --sourceRepo <R1>
     [--createdWithin <dur>]

  $0 prepopulate --serverid <id> --targetRepo <R2>
     ( --sourceRepo <R1> [--createdWithin <dur>]
     | --fromFile <PATH> )
     [--registryHost <host>] [--keep-local] [--dry-run]

Flags:
  --serverid <id>       JFrog CLI server ID.
  --sourceRepo <R1>     Docker remote whose cache we enumerate.
  --targetRepo <R2>     Docker remote to warm.
  --fromFile <PATH>     Read image ref list from a file (one per line, # for comments).
  --createdWithin <dur> AQL filter on 'created' (e.g. 1y, 6mo, 30d).
  --registryHost <host> Docker registry hostname. Default: derived from JFrog URL.
  --keep-local          Keep pulled images in the local docker daemon.
                        Default: 'docker rmi' each image after pull to save disk.
  --dry-run             Print jf docker pull commands, do not execute.
  --verbose, -v         Print per-tag details during list (which fat
                        manifest entries matched R1's cached digests,
                        fallback decisions, etc.). Off by default.

Examples:
  $0 list --serverid sum2 --sourceRepo docker-remote --createdWithin 1y
  $0 prepopulate --serverid sum2 --targetRepo docker-remote2 --fromFile refs.txt
EOF
  exit 1
}

# ---------- Parse args ----------
subcommand="${1:-}"
shift || usage

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serverid)       serverid="$2"; shift 2 ;;
    --sourceRepo)     sourceRepo="$2"; shift 2 ;;
    --targetRepo)     targetRepo="$2"; shift 2 ;;
    --createdWithin)  createdWithin="$2"; shift 2 ;;
    --fromFile)       fromFile="$2"; shift 2 ;;
    --registryHost)   registryHost="$2"; shift 2 ;;
    --keep-local)     keep_local="true"; shift ;;
    --dry-run)        dryrun="true"; shift ;;
    --verbose|-v)     verbose="true"; shift ;;
    --help|-h)        usage ;;
    *) log "ERROR: unknown flag $1"; usage ;;
  esac
done

# ---------- Preflight ----------
[[ -z "$serverid" ]] && { log "ERROR: --serverid is required"; usage; }

if ! jf c show "$serverid" >/dev/null 2>&1; then
  log "ERROR: server ID '$serverid' not configured. Run 'jf c add' first."
  exit 1
fi

# ---------- Config export (just for docker registry hostname) ----------
# We only need JF_URL to derive the default docker registry host.
# Credentials are handled by 'jf docker pull --server-id' — no manual
# docker login needed.
server_json=$(jf c export "$serverid" 2>/dev/null | base64 --decode 2>/dev/null || true)
if [[ -z "$server_json" ]]; then
  log "ERROR: could not export server config for '$serverid'"
  exit 1
fi

JF_URL=$(echo "$server_json" | jq -r '.url // .artifactoryUrl // empty' | sed 's|/$||')

# Extract host for docker registry addressing.
# Artifactory URL is typically https://<host>/artifactory or https://<host>.jfrog.io
default_host=$(echo "$JF_URL" | sed -E 's|^https?://([^/]+).*|\1|')

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

  # Enumerate TAG folders only (paths NOT under sha256__).
  # Each tag folder holds one of:
  #   list.manifest.json  - multi-arch OCI/Docker fat manifest
  #   manifest.json       - single-arch manifest
  # Digest folders (image/sha256__xxx/manifest.json) are enumerated
  # separately when needed to cross-reference cached arches.
  #
  # Also exclude .jfrog internal metadata folder.
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

# Convert AQL result to image:tag.
# `jf rt s` returns .path with the filename appended (unlike raw AQL which
# separates them). We strip the trailing manifest filename first, then
# split the remainder into image+tag on the last "/".
#   library/alpine/latest/list.manifest.json  →  library/alpine:latest
#   myorg/deep/name/1.2.3/manifest.json       →  myorg/deep/name:1.2.3
# Enumerate tag folders in R1, fetch each fat manifest, cross-reference
# with cached digest folders, and emit "image:tag#platform" per cached arch.
#
# Output format:
#   library/alpine:latest#linux/amd64
#   library/alpine:latest#linux/arm64
#   library/busybox:latest             (no platform if single-arch)
#
# Attestations (platform.architecture == "unknown") are skipped.
# Cached digests that R1 doesn't actually have are skipped.
run_search() {
  local repo_cache="${sourceRepo}-cache"

  log "Searching ${sourceRepo}-cache for tag manifests..."

  # Step 1: get all tag paths (image/tag/manifest-or-list.json)
  local tag_paths
  tag_paths=$(jf rt s --spec="$spec_file" --server-id="$serverid" \
    | jq -r --arg prefix "${repo_cache}/" '
        .[] | .path | sub("^" + $prefix; "")
      ' | sort -u)

  local tag_count
  tag_count=$(awk 'NF' <<< "$tag_paths" | awk 'END{print NR}')
  log "Found ${tag_count} tag folders. Fetching fat manifests to derive platforms..."

  # DEBUG: dump the raw tag_paths content so we can see what we're iterating
  if [[ "${DEBUG:-}" == "1" ]] || [[ "$tag_count" -eq 0 ]]; then
    log "DEBUG: raw tag_paths content follows (between --- markers):"
    log "---"
    while IFS= read -r LINE; do
      log "  [${#LINE}] ${LINE}"
    done <<< "$tag_paths"
    log "---"
  fi

  # Step 2: enumerate all cached digest folders in R1 (one API call, reused below)
  local cached_digests_file="/tmp/prepop_cached_digests.$$"
  jf rt curl -X POST /api/search/aql \
    --server-id="$serverid" \
    -H "Content-Type: text/plain" \
    --data-binary "items.find({\"repo\":\"${repo_cache}\",\"name\":\"manifest.json\",\"path\":{\"\$match\":\"*sha256__*\"}}).include(\"path\")" \
    2>/dev/null \
    | jq -r --arg prefix "${repo_cache}/" '
        .results[]?.path
        | sub("^" + $prefix; "")
        | capture("(?<image>.+)/sha256__(?<hex>[0-9a-f]+)$")
        | "\(.image)@sha256:\(.hex)"
      ' | sort -u > "$cached_digests_file"

  local cached_count
  cached_count=$(awk 'END{print NR}' "$cached_digests_file")
  log "R1 has ${cached_count} cached arch manifests across all tags."

  # Step 3: for each tag path, fetch the manifest content and derive refs
  > "$out_list"
  while IFS= read -r TAG_PATH; do
    [[ -z "$TAG_PATH" ]] && continue

    local tag_file="${TAG_PATH##*/}"          # manifest.json or list.manifest.json
    local image_tag_dir="${TAG_PATH%/*}"      # library/alpine/latest
    local tag="${image_tag_dir##*/}"          # latest
    local image="${image_tag_dir%/*}"         # library/alpine

    [[ "$verbose" == "true" ]] && log "  ${image}:${tag}  (from ${tag_file})"

    if [[ "$tag_file" == "list.manifest.json" ]]; then
      # Multi-arch: fetch fat manifest via the Docker Registry v2 API endpoint.
      # We use this rather than direct storage GET because expired-but-not-yet-
      # evicted cache entries return 404 on direct GET but transparently refresh
      # via the Docker API.
      local docker_endpoint="/api/docker/${sourceRepo}/v2/${image}/manifests/${tag}"
      local fat
      fat=$(jf rt curl -s "$docker_endpoint" \
              -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json" \
              --server-id="$serverid" 2>/dev/null)

      # Sanity-check the response (always visible — this is a real problem)
      if [[ -z "$fat" ]] || ! echo "$fat" | jq -e '.manifests' >/dev/null 2>&1; then
        log "  WARN: could not parse fat manifest for ${image}:${tag}"
        [[ "$verbose" == "true" ]] && log "        Response head: $(echo "$fat" | head -c 200)"
        continue
      fi

      local total_platforms
      total_platforms=$(echo "$fat" | jq '.manifests | length')
      [[ "$verbose" == "true" ]] && log "    Fat manifest lists ${total_platforms} entries"

      # Emit each platform whose referenced digest is in R1's cache
      local emitted=0
      while IFS='|' read -r digest_ref pull_ref; do
        [[ -z "$digest_ref" ]] && continue
        if grep -Fxq "$digest_ref" "$cached_digests_file"; then
          echo "$pull_ref" >> "$out_list"
          emitted=$((emitted + 1))
        fi
      done < <(echo "$fat" | jq -r --arg image "$image" --arg tag "$tag" '
        .manifests[]?
        | select(.platform.architecture != "unknown" and .platform.os != "unknown"
                 and (.platform.architecture // "") != ""
                 and (.platform.os // "") != "")
        | "\($image)@\(.digest)|\($image):\($tag)#\(.platform.os)/\(.platform.architecture)"
      ')
      [[ "$verbose" == "true" ]] && log "    Kept ${emitted} platform(s) matching cached digests"

      # If nothing matched, R1 likely has only stale/orphaned cache entries
      # for this tag (e.g. old fat manifest stored by digest, upstream
      # republished since). Fall back to emitting the tag alone so docker
      # resolves to the default arch and R2 still gets warmed.
      if [[ $emitted -eq 0 && $total_platforms -gt 0 ]]; then
        [[ "$verbose" == "true" ]] && log "    No cached arch matched fat manifest — falling back to tag-only pull"
        echo "${image}:${tag}" >> "$out_list"
      fi
    else
      # Single-arch: no fat manifest, no --platform needed
      echo "${image}:${tag}" >> "$out_list"
      [[ "$verbose" == "true" ]] && log "    Single-arch tag"
    fi
  done <<< "$tag_paths"

  # Dedupe (multiple tags might share a platform entry, in theory)
  sort -u -o "$out_list" "$out_list"

  # Count with awk to avoid grep -c || echo 0 doubling-up when there's no match
  local out_count multiarch single
  out_count=$(awk 'END{print NR}' "$out_list")
  multiarch=$(awk '/#/{c++} END{print c+0}' "$out_list")
  single=$((out_count - multiarch))

  # Keep the cached_digests file for debugging if nothing was emitted
  if [[ "$out_count" -eq 0 ]]; then
    log "WARN: no refs emitted. Debug info:"
    log "  Cached digests preserved for inspection: ${cached_digests_file}"
    log "  Sample of what R1 has cached:"
    head -3 "$cached_digests_file" | while read -r line; do log "    $line"; done
  else
    rm -f "$cached_digests_file"
  fi

  log "Emitted ${out_count} pull refs: ${multiarch} platform-scoped, ${single} single-arch. List: ${out_list}"
}

# ---------- Docker operations ----------

# Pull one image ref through R2 using jf docker pull.
# jf handles auth via --server-id; no manual login needed.
prepopulate_one() {
  local input_line="$1"     # e.g. library/alpine:latest  OR  library/alpine:latest#linux/amd64
  local host="$2"           # e.g. sum2.jfps.team
  local repo="$3"           # e.g. docker-remote2

  # Split image_ref#platform on '#' (platform is optional)
  local image_ref="${input_line%%#*}"
  local platform=""
  if [[ "$input_line" == *"#"* ]]; then
    platform="${input_line#*#}"
  fi

  local pull_ref="${host}/${repo}/${image_ref}"
  local display="${image_ref}"
  [[ -n "$platform" ]] && display="${image_ref} (${platform})"

  # Build the jf docker pull command
  local pull_cmd=(jf docker pull "$pull_ref" --server-id="$serverid")
  [[ -n "$platform" ]] && pull_cmd+=(--platform="$platform")

  if [[ "$dryrun" == "true" ]]; then
    log "  DRY   ${pull_cmd[*]}"
    echo "${input_line},DRY" >> "$report_csv"
    return
  fi

  printf "[%s]   ...   %s" "$(date '+%H:%M:%S')" "${display}"

  local pull_log="/tmp/docker_pull_$$.log"
  local rc=0
  if "${pull_cmd[@]}" >"$pull_log" 2>&1; then
    rc=0
  else
    rc=$?
  fi

  printf "\r[%s]   " "$(date '+%H:%M:%S')"
  if [[ $rc -eq 0 ]]; then
    printf "OK    [200]  %s\n" "${display}"
    echo "${input_line},200" >> "$report_csv"
    if [[ "$keep_local" != "true" ]]; then
      docker rmi "$pull_ref" >/dev/null 2>&1 || true
    fi
  else
    # Distinguish common failure modes from jf docker pull's stderr
    local err_line status
    err_line=$(tail -3 "$pull_log" | tr '\n' ' ' | head -c 200)
    if grep -qi "manifest.*not found\|not found: manifest\|does not exist" "$pull_log"; then
      status="404"
      printf "MISS  [404]  %s  (not in upstream)\n" "${display}"
    elif grep -qi "denied\|unauthorized\|authentication required" "$pull_log"; then
      status="403"
      printf "BLOCK [403]  %s  (Curation denied or auth failed)\n" "${display}"
    else
      status="FAIL"
      printf "FAIL  [---]  %s  (%s)\n" "${display}" "${err_line}"
    fi
    echo "${input_line},${status}" >> "$report_csv"
  fi

  rm -f "$pull_log"
}

prepopulate_all() {
  local input_list="$1"
  local host="$2"
  local repo="$3"

  report_csv="docker-prepop-report-${repo}-$(date +%Y%m%d-%H%M%S).csv"
  echo "image_ref,status" > "$report_csv"

  [[ "$dryrun" == "true" ]] && log "DRY RUN - no jf docker pulls will run"
  log "Pre-populating ${repo} via jf docker pull on ${host}..."

  local count=0
  while IFS= read -r LINE || [[ -n "$LINE" ]]; do
    LINE="${LINE%$'\r'}"
    LINE="${LINE#"${LINE%%[![:space:]]*}"}"
    LINE="${LINE%"${LINE##*[![:space:]]}"}"
    [[ -z "$LINE" ]] && continue
    [[ "$LINE" == \#* ]] && continue
    prepopulate_one "$LINE" "$host" "$repo"
    count=$((count + 1))
  done < "$input_list"

  log "Complete. ${count} tags processed. Report: ${report_csv}"
  log "Summary:"
  awk -F',' 'NR>1 {c[$2]++} END {for (s in c) printf "  %-6s : %d\n", s, c[s]}' \
    "$report_csv" | sort
}

# ---------- Subcommands ----------
cmd_list() {
  [[ -z "$sourceRepo" ]] && { log "ERROR: --sourceRepo required"; usage; }
  log "=== List mode (docker) ==="
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

  if ! command -v docker >/dev/null 2>&1; then
    log "ERROR: docker CLI not found on this host"
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    log "ERROR: docker daemon not reachable. Start Docker Desktop / dockerd first."
    exit 1
  fi

  local host="${registryHost:-$default_host}"

  log "=== Prepopulate mode (docker) ==="
  log "Target repo:    ${targetRepo}"
  log "Registry host:  ${host}"
  log "Keep local:     ${keep_local}"
  log "Dry-run:        ${dryrun}"

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

  prepopulate_all "$input_list" "$host" "$targetRepo"
  log "=== Done ==="
}

# ---------- Main ----------
case "$subcommand" in
  list)        cmd_list ;;
  prepopulate) cmd_prepopulate ;;
  *)           usage ;;
esac