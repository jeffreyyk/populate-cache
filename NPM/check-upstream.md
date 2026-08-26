# check-upstream (npm)

Companion to [prepopulate-r2](./prepopulate-r2.md). Given a list of npm tarball paths, HEAD each one directly against the upstream URL configured on R1 (usually `https://registry.npmjs.org`). Available as both a bash script (`check-upstream.sh`) and a Python port (`python/check-upstream.py`) with concurrency.

Emits a report of statuses plus a text file listing only the missing ones, ready to feed into rescue-local remediation.

## What it does

Reads the upstream URL from R1's config, then for each artifact path:

```
HEAD <upstream>/<pkg>/-/<pkg>-<version>.tgz
```

Uses `-sSLI` (silent, follow redirects, HEAD). npmjs.org and most mirrors redirect to CDNs so `-L` is required. `-I` (rather than `-X HEAD`) prevents Content-Length-driven stalls.

Note: check-upstream operates on **artifact paths** (like `eslint/-/eslint-8.57.0.tgz`), not `pkg@version` coords. The prepopulate list uses coords; check-upstream lists tarball paths directly from AQL. If you need to convert, the mapping is deterministic:

```
pkg@version           →  <pkg>/-/<pkg>-<version>.tgz
@scope/pkg@version    →  @scope/pkg/-/pkg-<version>.tgz
```

## Prerequisites

- **`jf` CLI** — configured with a server ID. Verify: `jf c show <serverid>`
- **`jq` and `curl`** — on PATH
- **Python 3.8+ and `requests`** (Python mode only) — `pip install requests`

## Quick start

**Bash:**
```bash
# Using an existing artifact-path list
./check-upstream.sh \
  --serverid psblr --sourceRepo sum-cba-npm-remote \
  --fromFile npm-artifacts-paths.txt

# Auto-enumerate from R1
./check-upstream.sh \
  --serverid psblr --sourceRepo sum-cba-npm-remote \
  --downloadedWithin 1y

# Verbose timing (dns/tls/ttfb/total per file)
./check-upstream.sh \
  --serverid psblr --sourceRepo sum-cba-npm-remote \
  --downloadedWithin 1y -v
```

**Python (with concurrency):**
```bash
cd python/

python3 check-upstream.py \
  --serverid psblr --sourceRepo sum-cba-npm-remote \
  --downloadedWithin 1y --concurrency 8
```

## Flags

```
--serverid <id>             JFrog CLI server ID
--sourceRepo <repo>         R1 npm remote (only used to read upstream URL)
--fromFile <path>           Read artifact-path list from file (mutually exclusive with time filters)
--downloadedWithin <dur>    AQL filter on stat.downloaded (e.g. 1y, 6mo)
--createdWithin <dur>       Additional AQL filter on created
--connect-timeout <sec>     TCP+TLS connect timeout (default 10s)
--verbose, -v               Per-file phase timing
--concurrency N             Python only: parallel HEAD workers (default 8)
```

Duration format: `1d`, `1w`, `6mo`, `1y`.

Input file format: one artifact path per line (like `eslint/-/eslint-8.57.0.tgz`). Lines starting with `#` and blank lines are ignored. Trailing `\r` is stripped automatically.

## Artifact path format

```
<pkg>/-/<pkg>-<version>.tgz              regular package
@<scope>/<pkg>/-/<pkg>-<version>.tgz     scoped package
```

Examples:
```
eslint/-/eslint-8.57.0.tgz
lodash/-/lodash-4.17.21.tgz
@babel/code-frame/-/code-frame-7.29.7.tgz
@types/node/-/node-18.15.0.tgz
```

## Output files

- **`upstream-check-<repo>-<timestamp>.csv`** — full report. Columns: `artifact_path,upstream_status`.
- **`upstream-missing-<repo>-<timestamp>.txt`** — one artifact path per line, only entries where the status was 404. Deleted automatically if empty.

Summary printed at the end:

```
Summary (by status):
  200      : 487
  404      : 3
3 artifact(s) missing from upstream: upstream-missing-<ts>.txt
```

## Interpreting results

| Console label | Status | Meaning | Action |
|---|---|---|---|
| `OK    [200]` | 200 | Tarball exists on upstream | Nothing to do |
| `AUTH  [401/403]` | 401/403 | Upstream requires auth | Check R1's upstream credentials (or your network path) |
| `MISS  [404]` | 404 | Tarball missing from upstream | Feed into rescue-local remediation |
| `FAIL  [---]` | 000 | Network / timeout / connection error | Retry, check network path |

## Concurrency (Python only)

`--concurrency N` (default 8) enables parallel HEAD workers. Registry.npmjs.org tarballs are served via CloudFront CDN and tolerate high concurrency well — 5-10x speedup with `--concurrency 8` is typical.

Recommended values:
- npmjs.org (public): `8-16`
- Private Verdaccio / Nexus: `4-8`
- GitHub Packages: `4` (stricter rate limits)

Progress counter `[X/N]` appears on each result line; elapsed time at completion.

## Rescue-local remediation

For paths flagged 404:

1. Create an npm rescue local repo (e.g. `<prefix>-npm-rescue-local`).
2. Copy affected `.tgz` files from R1's cache — the artifact path in R1's cache matches the missing.txt line exactly:
   ```bash
   # For "eslint/-/eslint-8.57.0.tgz"
   jf rt cp \
     <R1>-cache/eslint/-/eslint-8.57.0.tgz \
     <rescue-local>/eslint/-/eslint-8.57.0.tgz

   # For "@babel/code-frame/-/code-frame-7.29.7.tgz"
   jf rt cp \
     "<R1>-cache/@babel/code-frame/-/code-frame-7.29.7.tgz" \
     "<rescue-local>/@babel/code-frame/-/code-frame-7.29.7.tgz"
   ```
3. Add rescue local to virtual V1 alongside R2 with R2 checked first, rescue as fallback.

**Trade-off:** Curation only intercepts remotes. Rescue-local artifacts bypass Curation. Compensating: Xray still indexes them; scope discipline (only confirmed-missing tarballs); treat as frozen and sunset as pins upgrade.

## Diagnosing slow responses

With `-v` (bash), each file gets a timing line:

```
[..]   OK    [200]  lodash/-/lodash-4.17.21.tgz
[..]         timing: dns=0.005 tls=0.148 ttfb=0.301 total=0.302
```

- `dns` / `tls` — sub-second in healthy conditions
- `ttfb` — npmjs.org via CloudFront: 100-300ms typical
- `total` ≈ `ttfb` for HEAD

Python's verbose format is coarser: `elapsed=X total=Y` since `requests` doesn't expose all curl phase timers.

## Troubleshooting

**All checks return 401 or 403** — upstream requires auth. Public npmjs.org is anonymous-read; this only happens against private mirrors. Check R1's config:
```bash
jf rt curl "/api/repositories/<sourceRepo>" --server-id <id> \
  | jq '{key, rclass, url, username}'
```

**Redirects to unexpected hosts** — npmjs.org redirects to `registry.npmjs.org` and then CloudFront (`.cloudfront.net`), which is normal. If you see redirects to a corporate proxy landing page (like a Zscaler `package-reroute` URL), your network is intercepting outbound HTTPS. `--via-r1` isn't implemented for npm yet — ask if you need it.

**Everything returns FAIL** — network path broken. Manual test:
```bash
curl -sSLI -o /dev/null -w "http=%{http_code}\n" \
  https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz
```
Expected: `http=200`. If not, network path to npmjs.org is the issue.

**Scoped packages 404 unexpectedly** — check the artifact path includes the leading `@`. `@babel/code-frame/-/code-frame-7.29.7.tgz` is correct; `babel/code-frame/-/code-frame-7.29.7.tgz` (missing `@`) will 404.

**Rate limiting** — rare from npmjs.org (CDN-cached); more common from private mirrors. Drop `--concurrency` if you see `429` or `Connection reset by peer`.

## Related

- [`prepopulate-r2.md`](./prepopulate-r2.md) — companion prepopulate script
- [`README.md`](./README.md) — NPM folder overview and quick-start
- [`python/README.md`](./python/README.md) — Python-specific setup and concurrency notes
- [`../README.md`](../README.md) — top-level index of all package types
