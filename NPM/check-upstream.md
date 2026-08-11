# check-upstream.sh

Detect artifacts that have been removed from the upstream registry.

Given a list of artifact paths (from a file or from AQL against a remote repo's cache), the script tests each one against the upstream URL configured on that remote. Anything the upstream no longer has returns 404 — and those are the artifacts that need [rescue-local remediation](./README.md#the-404-case--rescue-local-remediation) before an R1 → R2 migration cutover, because R2 won't be able to fetch what upstream doesn't have anymore.

Companion script to [prepopulate-r2.sh](./README.md).

## When to run this

- **Before pre-populating R2** — to know which artifacts will fail cleanly at pre-populate time vs. which ones need to be rescued into a local repo instead.
- **Ad-hoc auditing** — to check whether specific packages your teams depend on still exist upstream (useful when a security advisory unpublishes something and you need to know the blast radius).

## How it works

1. Reads the source repo config via `jf rt curl -X GET /api/repositories/<repo>` and extracts the upstream `url` field.
2. For each artifact path in the input list, issues `curl -I -L` against `<upstream_url>/<artifact_path>`.
3. Records the HTTP status per artifact.
4. Writes two files: the full CSV report and a filtered plain-text list of just the 404s.

Nothing is downloaded — only HTTP headers are exchanged. Bandwidth per artifact is a few kilobytes regardless of package size.

## Prerequisites

- `jf` CLI configured with a server ID that has read access to the source repo's config.
- `jq` for JSON parsing.
- `curl`.
- Direct network egress to the upstream registry (e.g. `registry.npmjs.org`, `pypi.org`, `repo1.maven.org`).

If your workstation is behind a corp proxy, either set `HTTPS_PROXY` in the environment or run the script from a host that has direct upstream access.

## Quick start

```bash
# Check a pre-built list against the R1 upstream
./check-upstream.sh --serverid sum2 --sourceRepo npm-remote --fromFile artifacts.txt

# Check everything R1 has cached in the last year of activity
./check-upstream.sh --serverid sum2 --sourceRepo npm-remote --downloadedWithin 1y

# Verbose mode - show URLs and per-request timing
./check-upstream.sh --serverid sum2 --sourceRepo npm-remote --fromFile artifacts.txt -v
```

## Flag reference

| Flag | Required | Description |
|---|---|---|
| `--serverid <id>` | yes | JFrog CLI server ID |
| `--sourceRepo <name>` | yes | Remote repo whose upstream URL we test against |
| `--fromFile <path>` | one of | Read artifact list from a file (one path per line, `#` for comments) |
| `--downloadedWithin <dur>` | one of | AQL against the repo's cache with `stat.downloaded` filter |
| `--createdWithin <dur>` | no | Alternative time filter on `created` |
| `--connect-timeout <sec>` | no | TCP+TLS connect timeout. Default 10s. |
| `--verbose`, `-v` | no | Print URL and per-request curl timing (dns / tls / ttfb / total) |

**Duration format**: `1d`, `1w`, `6mo`, `1y`.

**Input file format**: one artifact path per line, repo-relative (no `<repo>-cache/` prefix). Lines starting with `#` and blank lines are ignored. Trailing `\r` from Windows-edited files is stripped automatically.

## Output files

Two files land in the current directory:

- **`upstream-check-<repo>-<timestamp>.csv`** — full CSV report. Columns: `artifact_path,upstream_status`.
- **`upstream-missing-<repo>-<timestamp>.txt`** — plain text list of just the 404s, one path per line. Only created if there are missing artifacts. Ready to feed straight into the rescue-local step.

Summary is also printed at the end:

```
HTTP 200 : 847
HTTP 404 :  12
```

## Interpreting results

| Status | Label | Meaning | Action |
|---|---|---|---|
| 200 | `OK` | Still available upstream | Nothing to do — R2 will fetch it cleanly. |
| 404 | `MISS` | Removed from upstream | Feed into rescue-local remediation. |
| 401 / 403 | `AUTH` | Upstream requires auth | Upstream is private; anonymous check can't confirm. Either provide creds (out of scope for this script) or rely on R1's cache as ground truth. |
| 000 | `FAIL` | Network error, timeout, DNS failure | Check network connectivity, retry. `--verbose` shows the underlying curl error. |
| Other | `[NNN]` | Unusual status | Investigate case by case — 5xx from upstream, 429 rate limit, redirect loops. |

## Verbose mode

`-v` adds two extra lines per artifact:

```
[10:15:22]   URL   https://registry.npmjs.org/yargs-parser/-/yargs-parser-21.1.1.tgz
[10:15:23]   OK    [200]  yargs-parser/-/yargs-parser-21.1.1.tgz
[10:15:23]            timing: dns=0.012 tls=0.234 ttfb=0.410 total=1.423
```

The timing breakdown separates the phases:

- **`dns`** — DNS resolution. Should be milliseconds; if consistently high, your resolver is slow or the upstream domain has unusual DNS behavior.
- **`tls`** — TCP + TLS handshake completion. Typically 100–300ms; if higher, the network path to the upstream is slow.
- **`ttfb`** — time to first byte. This is when the upstream started responding. High values here mean the upstream server itself is slow.
- **`total`** — end-to-end time for the whole HEAD (including redirects if `-L` follows any).

Use this when a run is unexpectedly slow — the phase breakdown tells you whether to blame DNS, network path, or the upstream server.

## Troubleshooting

**`ERROR: could not read upstream URL for <repo>`**
The source repo doesn't exist, isn't a remote type, or the token doesn't have read access to its config. Verify with:
```bash
jf rt curl -X GET "/api/repositories/<repo>" --server-id <id> | jq '.rclass, .url'
```

**All statuses come back as `FAIL`**
Direct upstream access is blocked from your host. Test manually:
```bash
curl -sSLI https://registry.npmjs.org/yargs-parser/-/yargs-parser-21.1.1.tgz
```
If that fails too, the issue is network egress, not the script. Try running from a host with direct upstream access, or set `HTTPS_PROXY`.

**Script runs much slower than a manual curl to the same URL**
Run with `-v` and check the timing breakdown per artifact. A common cause is Windows-style line endings in a hand-edited input file (the script now strips these automatically, but pre-strip your file if unsure):
```bash
tr -d '\r' < artifacts.txt > artifacts-clean.txt
```

**`AUTH` on artifacts that were previously accessible**
The upstream may have moved a package behind auth (e.g. npm private packages that were previously public). Rare, but worth checking the specific package on the upstream's website.

**Docker repos**
Not currently supported. Docker's upstream check needs manifest-level probing against the registry's API (`/v2/<name>/manifests/<tag>`), not simple HEAD to a URL. If needed, we can add a `--packageType docker` mode.

## Related

- **[prepopulate-r2.sh (README.md)](./README.md)** — companion script that warms R2 with the still-available artifacts.

