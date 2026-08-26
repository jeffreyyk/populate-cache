# check-upstream-pypi

Companion to [prepopulate-r2-pypi](./prepopulate-r2-pypi.md). Given a list of `pkg==version` pairs, GET each package's PEP 503 simple index and grep the response body for the specific version filename to confirm the version exists. Available as both a bash script (`check-upstream-pypi.sh`) and a Python port (`python/check-upstream-pypi.py`) with concurrency.

Emits a report of statuses plus a text file listing only the missing ones, ready to feed into rescue-local remediation.

## What it does

For each `pkg==version`:

```
GET <upstream>/simple/<normalized-pkg>/
```

If the response is 200, grep the body for `<pkg>-<version>-` (wheel prefix) or `<pkg>-<version>.` (sdist). If either found → OK. If neither → the specific version is yanked or missing.

Two distinct "missing" flavors:
- **`MISS_PKG`** (index returns 404) → entire package gone from upstream
- **`MISS_VER`** (index returns 200 but version substring not present) → specific version yanked

Both collapse to CSV status `404` so rescue-local filtering only needs one status; the label difference is only for humans.

Package name normalization follows PEP 503: lowercase, collapse runs of `[-_.]` to a single `-`.

## Why GET (not HEAD)

PyPI's simple index responds to HEAD with just a status code — no body. We need the body to check for the specific version filename. GET is the only way. Response bodies are small (index pages, no artifacts) so it's not slow.

## Prerequisites

- **`jf` CLI** — configured with a server ID. Verify: `jf c show <serverid>`
- **`jq` and `curl`** — on PATH
- **Python 3.8+ and `requests`** (Python mode only) — `pip install requests`

## Quick start

**Bash:**
```bash
# Using an existing coord list
./check-upstream-pypi.sh \
  --serverid psblr --sourceRepo sum-cba-pypi-remote \
  --fromFile pypi-artifacts-*.txt

# Auto-enumerate from R1
./check-upstream-pypi.sh \
  --serverid psblr --sourceRepo sum-cba-pypi-remote \
  --downloadedWithin 1y

# Via R1 (Zscaler / corporate proxy workaround)
./check-upstream-pypi.sh \
  --serverid psblr --sourceRepo sum-cba-pypi-remote \
  --fromFile pypi-artifacts-*.txt --via-r1
```

**Python (with concurrency):**
```bash
cd python/

python3 check-upstream-pypi.py \
  --serverid psblr --sourceRepo sum-cba-pypi-remote \
  --fromFile pypi-artifacts-*.txt --concurrency 8

# Via R1 (Zscaler workaround)
python3 check-upstream-pypi.py \
  --serverid psblr --sourceRepo sum-cba-pypi-remote \
  --fromFile pypi-artifacts-*.txt --concurrency 8 --via-r1
```

## Flags

```
--serverid <id>             JFrog CLI server ID
--sourceRepo <repo>         R1 PyPI remote (only used to read upstream URL)
--fromFile <path>           Read pkg==version list from file (mutually exclusive with time filters)
--downloadedWithin <dur>    AQL filter on stat.downloaded (e.g. 1y, 6mo)
--createdWithin <dur>       Additional AQL filter on created
--via-r1                    Route GET through R1's own /api/pypi/ endpoint on the tenant
                            instead of hitting upstream directly. Use when corporate
                            proxies (Zscaler etc.) block pypi.org from the client.
--connect-timeout <sec>     TCP+TLS connect timeout (default 10s)
--verbose, -v               Per-file phase timing
--concurrency N             Python only: parallel GET workers (default 8)
```

Duration format: `1d`, `1w`, `6mo`, `1y`.

Input file format: one `pkg==version` per line. Same format as prepopulate consumes. Lines starting with `#` and blank lines are ignored. Trailing `\r` is stripped automatically.

## URL patterns

Direct upstream:
```
GET <upstream>/simple/<norm-pkg>/
```

`--via-r1` mode:
```
GET <tenant>/api/pypi/<sourceRepo>/simple/<norm-pkg>/
```

**Special case: `files.pythonhosted.org`** — that host is the CDN for actual artifacts, not the index. If R1's upstream is set to `files.pythonhosted.org`, the script auto-swaps to `https://pypi.org` for simple-index checks and logs the swap.

## Coordinate format

```
pkg==version                 pinned version
```

Package names are PEP 503 normalized internally for URL construction:
```
Requests            → requests
setuptools_scm      → setuptools-scm
python-Levenshtein  → python-levenshtein
```

## Output files

- **`upstream-check-pypi-<repo>-<timestamp>.csv`** — full report. Columns: `pkg,version,upstream_status`.
- **`upstream-missing-pypi-<repo>-<timestamp>.txt`** — one `pkg==version` per line, only entries flagged missing (either 404 index or yanked version). Deleted automatically if empty.

Summary printed at the end:

```
Summary (by status):
  200      : 487
  404      : 8
8 pkg==version missing from upstream: upstream-missing-pypi-<ts>.txt
```

## Interpreting results

| Console label | CSV status | Meaning | Action |
|---|---|---|---|
| `OK    [200]` | 200 | Package + version exist on upstream | Nothing to do |
| `MISS  [200/yanked]` | 404 | Package exists but version yanked/missing | Feed into rescue-local remediation |
| `MISS  [404]` | 404 | Package not in upstream | Feed into rescue-local remediation |
| `AUTH  [401/403]` | 401/403 | Auth failed (or Zscaler intercepting) | Try `--via-r1` |
| `FAIL  [---]` | 000 | Network / timeout / connection error | Retry, check network path |

## Concurrency (Python only)

`--concurrency N` (default 8) enables parallel GET workers. Simple index responses are small and heavily CDN-cached (pypi.org uses Fastly), so speedup is roughly linear up to `--concurrency 16`.

Recommended values:
- pypi.org (public): `8-16`
- Private Devpi / Nexus: `4-8`
- Internal PyPI mirror: `4-8`

Progress counter `[X/N]` appears on each result line; elapsed time at completion.

## The Zscaler workaround (`--via-r1`)

In Zscaler-restricted enterprise environments, direct traffic from client machines to `pypi.org` is often blocked with a 307 redirect to `<zscaler>/package-reroute?...&action=deny`. When you see:

- All 401/403 with `via_r1=False` in the log
- Response comes back much faster than a real GET

...that's the pattern. `--via-r1` routes through your JFrog tenant's `api/pypi` endpoint using tenant credentials. The tenant's server-side outbound path IS on the Zscaler allowlist so it can reach upstream. This adds one hop but bypasses the client-side block.

## Rescue-local remediation

For entries flagged missing:

1. Create a PyPI rescue local repo (e.g. `<prefix>-pypi-rescue-local`).
2. Copy affected artifacts from R1's cache. PyPI cache layout in Artifactory is `<pkg>/<filename>`:
   ```bash
   # For "requests==2.31.0"
   jf rt cp \
     "<R1>-cache/requests/requests-2.31.0-py3-none-any.whl" \
     "<rescue-local>/requests/requests-2.31.0-py3-none-any.whl"
   jf rt cp \
     "<R1>-cache/requests/requests-2.31.0.tar.gz" \
     "<rescue-local>/requests/requests-2.31.0.tar.gz"
   ```
   Check R1 for the exact filenames first:
   ```bash
   jf rt curl "/api/search/artifact?name=requests-2.31.0&repos=<R1>-cache" --server-id <id>
   ```
3. Add rescue local to virtual V1 alongside R2 with R2 checked first, rescue as fallback.

**Trade-off:** Curation only intercepts remotes. Rescue-local artifacts bypass Curation. Compensating: Xray still indexes them; scope discipline (only confirmed-missing versions); treat as frozen and sunset as pins upgrade.

## Diagnosing slow responses

With `-v` (bash), each file gets a timing line:

```
[..]   OK    [200]  requests==2.31.0
[..]         timing: dns=0.005 tls=0.148 ttfb=0.201 total=0.202
```

- `dns` / `tls` — sub-second in healthy conditions
- `ttfb` — pypi.org via Fastly: 50-200ms typical
- `total` ≈ `ttfb` for the small index responses

Python's verbose format is coarser: `elapsed=X total=Y` since `requests` doesn't expose all curl phase timers.

## Troubleshooting

**All checks return 401 or 403 (direct upstream mode)** — Zscaler is blocking pypi.org from your machine. Add `--via-r1`. That's what the flag is for.

**All 401 in `--via-r1` mode** — server-id auth issue. Verify:
```bash
jf c show <serverid>
jf rt ping --server-id <serverid>
```

**Everything returns FAIL / 000** — network path broken. Manual test:
```bash
curl -sSLI -o /dev/null -w "http=%{http_code}\n" \
  https://pypi.org/simple/requests/
```
Expected: `http=200`. If not, network path to pypi.org is the issue → try `--via-r1`.

**Package returns MISS but you're sure it exists** — check PEP 503 normalization. Package name `Django` normalizes to `django`; `setuptools_scm` to `setuptools-scm`. If the input coord has non-normalized capitalization or `_`, that's fine — the script normalizes internally. If it's still MISS, the version may genuinely be yanked (rare but happens).

**MISS [200/yanked] on a version that should exist** — the simple index page returned 200 but our grep for `<pkg>-<version>-` and `<pkg>-<version>.` didn't match. Check the index page directly:
```bash
curl -sSL https://pypi.org/simple/requests/ | grep '2\.31\.0'
```
If nothing matches, the version really is gone. If your grep finds it but ours doesn't, the version string might have an unusual character — share the coord.

## Related

- [`prepopulate-r2-pypi.md`](./prepopulate-r2-pypi.md) — companion prepopulate script
- [`README.md`](./README.md) — PyPI folder overview and quick-start
- [`python/README.md`](./python/README.md) — Python-specific setup and concurrency notes
- [`../README.md`](../README.md) — top-level index of all package types
