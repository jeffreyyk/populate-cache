# prepopulate-r2-docker.sh

Docker analog of [prepopulate-r2.sh](./README.md). Enumerate Docker images in R1's cache, then use `jf docker pull` to fetch each image through R2 so R2's cache warms and Curation policies evaluate every artifact.



## What it does

**Two subcommands:**

- **`list`** — For each tag folder in R1's cache, fetch the fat manifest via Docker Registry v2 API, cross-reference each platform entry with R1's cached digest folders, and emit one line per real cached architecture. Attestations and orphaned entries are handled correctly.
- **`prepopulate`** — Read the list and for each entry run `jf docker pull` through R2. Auth is handled by jf CLI via `--server-id`; no manual `docker login` needed.



## Prerequisites

- Working `docker` daemon on the host running this script (`jf docker pull` shells out to real docker under the hood).
- `jf` CLI configured with a server ID for your Artifactory tenant. Auth is handled by `jf docker pull --server-id`, no manual `docker login`.
- `jq`.

Verify:

```bash
docker version
jf c show <your-server-id>
which jq
```

## Quick start

```bash
# 1. List R1's tags with per-arch coverage
./prepopulate-r2-docker.sh list \
  --serverid psblr --sourceRepo bmc-docker-remote
# → docker-tags-<pid>.txt

# 2. Dry-run against R2 to see the jf docker pull commands
./prepopulate-r2-docker.sh prepopulate \
  --serverid psblr --targetRepo testpopulate \
  --fromFile docker-tags-<pid>.txt \
  --dry-run

# 3. Real run
./prepopulate-r2-docker.sh prepopulate \
  --serverid psblr --targetRepo testpopulate \
  --fromFile docker-tags-<pid>.txt
```

## Flag reference

### `list` subcommand

| Flag | Required | Description |
|---|---|---|
| `--serverid <id>` | yes | JFrog CLI server ID |
| `--sourceRepo <name>` | yes | R1 Docker remote name (without `-cache` suffix) |
| `--createdWithin <dur>` | no | AQL filter on `created` (e.g. `1y`, `6mo`, `30d`) |
| `--verbose`, `-v` | no | Per-tag processing details (see below) |

### `prepopulate` subcommand

| Flag | Required | Description |
|---|---|---|
| `--serverid <id>` | yes | JFrog CLI server ID |
| `--targetRepo <name>` | yes | R2 Docker remote to warm |
| `--sourceRepo <name>` | one of | Auto-list from R1 as the source (delegates to `list`) |
| `--fromFile <path>` | one of | Read image ref list from a file |
| `--createdWithin <dur>` | no | Time filter when using `--sourceRepo` |
| `--registryHost <host>` | no | Docker registry hostname. Default: derived from JFrog URL |
| `--keep-local` | no | Keep pulled images in local docker. Default is to `docker rmi` after each pull |
| `--dry-run` | no | Print `jf docker pull` commands, do not execute |
| `--verbose`, `-v` | no | Verbose mode |

**Duration format**: `1d`, `1w`, `6mo`, `1y`.

**Input file format**: one image ref per line. Lines starting with `#` and blank lines are ignored. Trailing `\r` from Windows-edited files is stripped automatically.

## Coordinate format

```
image:tag                        → single-arch pull; docker resolves default arch
image:tag#os/arch                → multi-arch pull; --platform=os/arch pinned
```

Examples:

```
library/alpine:latest#linux/amd64
library/alpine:latest#linux/arm64
library/busybox:latest#linux/amd64
alpine/socat:latest              (fallback, no cached digest matched)
```

## Output files

- **`docker-tags-<pid>.txt`** — output of `list`, or intermediate from `prepopulate --sourceRepo`. One image ref per line.
- **`docker-prepop-report-<target>-<timestamp>.csv`** — from `prepopulate`. Columns: `image_ref,status`.

Summary printed at end of `prepopulate`:

```
Summary:
  200    : 4
  404    : 1
```

## Interpreting results

| Status | Label | Meaning | Action |
|---|---|---|---|
| 200 | `OK` | Image pulled successfully; R2 has all manifests and blobs | Nothing to do |
| 403 | `BLOCK` | Curation policy denied, or upstream auth failed | Review with security or check R1's upstream credentials |
| 404 | `MISS` | Image not in upstream | Feed into rescue-local remediation |
| FAIL | `FAIL` | Other error — network, docker daemon, corrupted manifest | See the error snippet in the report; retry after fixing |

The classification greps `jf docker pull` stderr for known error patterns. Some obscure errors may fall into FAIL where a more specific label would be nicer.

Common FAIL causes we've seen:
- `unsupported media type application/vnd.in-toto+json` — attestation slipped through. Should be filtered but worth double-checking.
- `unknown blob` — R2's upstream can't reach the referenced blob. Usually a repo-config issue: R2 isn't configured as a docker remote, or its upstream URL is wrong.
- `manifest unknown` — the tag exists in R1's cache but was removed upstream. Feed into rescue-local.

## Verbose mode

Default output is quiet — summary lines only. With `-v`, `list` prints per-tag processing:

```
[..] === List mode (docker) ===
[..] Source: bmc-docker-remote
[..] Searching bmc-docker-remote-cache for tag manifests...
[..] Found 3 tag folders. Fetching fat manifests to derive platforms...
[..] R1 has 4 cached arch manifests across all tags.
[..]   library/alpine:latest  (from list.manifest.json)
[..]     Fat manifest lists 16 entries
[..]     Kept 2 platform(s) matching cached digests
[..]   library/busybox:latest  (from list.manifest.json)
[..]     Fat manifest lists 17 entries
[..]     Kept 0 platform(s) matching cached digests
[..]     No cached arch matched fat manifest — falling back to tag-only pull
[..] Emitted 3 pull refs: 2 platform-scoped, 1 single-arch. List: docker-tags-<pid>.txt
```

Useful when the emitted list doesn't match expectations and you want to understand where a specific tag ended up (platform-scoped, fallback, or skipped).

## Rescue-local remediation

For refs flagged 404 by [check-upstream-docker.sh](./check-upstream-docker.md):

1. Create a Docker rescue local repo (e.g. `<prefix>-docker-rescue-local`).
2. Copy the affected image folders from `R1-cache` into the rescue local:
   ```bash
   # The tag folder (fat manifest)
   jf rt cp <R1>-cache/<image>/<tag>/ <rescue-local>/<image>/<tag>/ --recursive

   # Each cached arch manifest folder
   jf rt cp <R1>-cache/<image>/sha256__<hash>/ <rescue-local>/<image>/sha256__<hash>/ --recursive
   ```
3. Add the rescue local to virtual V1 alongside R2, ordered so R2 is checked first with rescue as fallback.

**Trade-off:** Curation only intercepts remotes. Artifacts in a local repo bypass Curation. Compensating controls: Xray still indexes; scope discipline (only confirmed-missing images, not bulk R1 copies); treat as frozen and sunset as pins move to non-removed replacements.



## Performance notes

`jf docker pull` is heavier than curl HEAD because it actually downloads all the layers to your local docker daemon. For a wave of images, that's the network cost you'd hit anyway on any real pull. `--keep-local=false` (the default) deletes them from your daemon after each pull to keep disk bounded.

Typical timings:
- Small image (`library/hello-world` at ~5KB): 5–10s per pull
- Medium image (`library/alpine` at ~5MB): 10–30s per pull
- Large image (`library/python` at ~1GB): 60s–5min per pull

For big waves, `jf docker pull` runs sequentially by default and you can't easily parallelize it because it shares the local docker daemon's storage. Options:
- Run overnight on a dedicated host
- Split the list into chunks by image size and run on multiple hosts
- Talk to a JFrog PS colleague about using their pre-population infrastructure