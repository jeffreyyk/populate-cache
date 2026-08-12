# check-upstream-docker.sh

Companion to [prepopulate-r2-docker.sh](./prepopulate-r2-docker.md). Given a list of Docker `image:tag` refs, HEAD each one **directly against the upstream registry** (DockerHub) to determine whether the image still exists upstream. R1's config is used only to discover the upstream URL — the actual checks bypass R1 entirely, so the answer reflects real upstream state regardless of R1's cache freshness.

Emits a report of statuses plus a text file listing only the missing ones, ready to feed into the rescue-local remediation step.


## What it does

For every input ref, sends:

```
HEAD <upstream>/v2/<image>/manifests/<tag>
```

directly at the upstream registry, following the Docker Registry v2 auth flow:

1. Try HEAD with whatever auth is on hand (Bearer token if `--upstreamAuthToken`, Basic auth if `--upstreamUser`/`--upstreamPassword`, otherwise anonymous).
2. If the server responds `401` with `Www-Authenticate: Bearer realm="..."`, extract the realm and service, `GET` the realm URL with `scope=repository:<image>:pull`, and get a token.
3. Retry the HEAD with the fresh Bearer token.
4. Report the final status.

## Auth handling

Docker upstreams vary a lot in how they gate access. The script handles the common cases:

| Upstream | Auth flow used | Config needed |
|---|---|---|
| DockerHub public images (`library/*`) | Bearer challenge (anonymous token) | None |
| DockerHub authenticated repos | Bearer challenge (with basic auth on token endpoint) | `--upstreamUser` / `--upstreamPassword` |
| Private Nexus / Harbor / Artifactory | Basic auth | `--upstreamUser` / `--upstreamPassword` |
| Anything with a static Bearer | Pre-obtained token | `--upstreamAuthToken` |

The bearer challenge is the standard Docker Registry v2 auth handshake — same one the `docker` CLI does under the hood. This works transparently for DockerHub, GHCR, Quay, and most cloud registries with public images.

## Coordinate format

Reads the same output format that `prepopulate-r2-docker.sh` emits:

```
image:tag                       # regular
image:tag#os/arch               # platform-scoped (from prepopulate list)
```

The `#os/arch` suffix is stripped before the HEAD — Docker's manifest API is tag-based, and a tag either exists upstream (at least one arch under it) or doesn't.

## Prerequisites

- `jf` CLI configured with a server ID (only used to read R1's config, not for the checks themselves).
- `jq`.
- `curl`.

Verify:

```bash
jf c show <your-server-id>
which jq curl
```

## Quick start

```bash
# Public images on DockerHub — anonymous with bearer challenge
./check-upstream-docker.sh \
  --serverid psblr --sourceRepo bmc-docker-remote \
  --fromFile docker-tags-*.txt

# Private upstream with basic auth
./check-upstream-docker.sh \
  --serverid psblr --sourceRepo my-nexus-remote \
  --fromFile docker-tags.txt \
  --upstreamUser myuser --upstreamPassword mypass

# Pre-obtained bearer token (e.g. from `docker login` config)
./check-upstream-docker.sh \
  --serverid psblr --sourceRepo bmc-docker-remote \
  --fromFile docker-tags.txt \
  --upstreamAuthToken 'eyJhbGciOi...'

# With per-image timing to diagnose slow upstreams
./check-upstream-docker.sh \
  --serverid psblr --sourceRepo bmc-docker-remote \
  --fromFile docker-tags-*.txt -v
```

## Flag reference

| Flag | Required | Description |
|---|---|---|
| `--serverid <id>` | yes | JFrog CLI server ID (only used to read R1's config) |
| `--sourceRepo <repo>` | yes | Docker remote whose upstream URL we resolve |
| `--fromFile <path>` | one of | Read `image:tag` list from a file |
| `--createdWithin <dur>` | one of | AQL filter on `created` (e.g. `1y`, `6mo`, `30d`) when auto-enumerating |
| `--upstreamUser <u>` | no | Upstream registry username for Basic auth |
| `--upstreamPassword <p>` | no | Upstream registry password for Basic auth |
| `--upstreamAuthToken <t>` | no | Pre-obtained Bearer token (overrides user/pass) |
| `--connect-timeout <sec>` | no | TCP+TLS connect timeout. Default 10s |
| `--verbose`, `-v` | no | Print per-image curl phase timing (dns/tls/ttfb/total) |

**Duration format**: `1d`, `1w`, `6mo`, `1y`.

**Input file format**: one `image:tag` per line, optionally with `#os/arch` suffix (stripped). Lines starting with `#` and blank lines are ignored. Trailing `\r` from Windows-edited files is stripped automatically.

## Output files

- **`upstream-check-docker-<repo>-<timestamp>.csv`** — full report. Columns: `image,tag,upstream_status`.
- **`upstream-missing-docker-<repo>-<timestamp>.txt`** — one `image:tag` per line, only entries where the status was 404. Deleted automatically if empty.

Summary printed at the end:

```
Summary (by status):
  200      : 47
  401      : 1
  404      : 3
1 image(s) missing from upstream: upstream-missing-docker-bmc-docker-remote-<ts>.txt
```

## Interpreting results

| Status | Label | Meaning | Action |
|---|---|---|---|
| 200 | `OK` | Image exists upstream | Nothing to do |
| 401 | `AUTH` | Auth failed on upstream (or bearer challenge didn't produce a valid token) | Pass `--upstreamUser`/`--upstreamPassword`, or `--upstreamAuthToken` |
| 403 | `AUTH` | Upstream denied access | Auth is present but insufficient — different repo scope, IP restriction, etc. |
| 404 | `MISS` | Not in upstream | Feed into rescue-local remediation |
| 429 | `RATE` | Rate-limited | DockerHub anonymous is capped at 100 pulls/6hr. Authenticate or wait |
| 000 | `FAIL` | Network / TLS / connection error | Retry, check network path to upstream |

## Rescue-local remediation

For refs flagged 404:

1. Create a Docker rescue local repo (e.g. `<prefix>-docker-rescue-local`).
2. Copy the affected image folders from `R1-cache` into the rescue local:
   ```bash
   # For each image:tag in upstream-missing-docker-*.txt
   jf rt cp <R1>-cache/<image>/<tag>/ <rescue-local>/<image>/<tag>/ --recursive
   # And its arch manifests
   jf rt cp <R1>-cache/<image>/sha256__<hash>/ <rescue-local>/<image>/sha256__<hash>/ --recursive
   ```
3. Add the rescue local to virtual V1 alongside R2, ordered so R2 is checked first with rescue as fallback.

**Trade-off:** Curation only intercepts remotes. Artifacts in a local repo bypass Curation. Compensating controls: Xray still indexes; scope discipline (only confirmed-missing images, not bulk R1 copies); treat as frozen and sunset as pins move to non-removed replacements.


## DockerHub rate limits

DockerHub has strict pull rate limits:

- Anonymous: 100 pulls per 6 hours per source IP
- Free authenticated: 200 pulls per 6 hours
- Paid: much higher

Each `check_one` counts as one HEAD → one "pull" against the DockerHub API. A run of 1000 anonymous DockerHub checks will get rate-limited (`429`) partway through. Options:

- Split runs across multiple 6-hour windows
- Use a paid DockerHub account for the check

Watch for `429` in the summary. If you see any, the rest of the run is compromised — retry from the last `200` after cooldown.