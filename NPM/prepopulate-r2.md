# prepopulate-r2 (npm)

Enumerate the npm tarballs in R1's cache and run `jf npm pack` for each one through R2 to warm R2's cache and trigger Curation policies. Available as both a bash script (`prepopulate-r2.sh`) and a Python port (`python/prepopulate-r2.py`) with concurrency.

Same behavior, same output — pick bash for zero-setup, Python for parallel packs.

## What it does

- **`list`** — AQL search over R1's cache for `.tgz` files. Skips the `.npm/` metadata folder. Parses `<pkg>/-/<pkg>-<version>.tgz` paths (including scoped packages like `@babel/code-frame`) and emits `pkg@version` per line.
- **`prepopulate`** — For each entry, runs `jf npm pack pkg@version` through R2. `jf npm pack` fetches both metadata (`.npm/<pkg>/package.json`) and tarball without pulling transitive deps (which `jf npm install` would). The `.tgz` is deleted after each pack to keep disk bounded.

## Why `jf npm pack` (not curl HEAD)

npm has a metadata protocol that direct HEAD doesn't warm. Curl HEAD on the tarball URL populates the `.tgz` but leaves `.npm/<pkg>/package.json` cold — subsequent `npm install` calls would still hit upstream. `jf npm pack` invokes npm's real resolver against R2, hitting both endpoints without side effects (no install, no deps).

## Prerequisites

- **`jf` CLI** — configured with a server ID. Verify: `jf c show <serverid>`
- **`jq`** — on PATH
- **`npm` binary** — `jf npm pack` shells out to real npm. Verify: `npm -v`
- **Python 3.8+ and `requests`** (Python mode only) — `pip install requests`

## Quick start

**Bash:**
```bash
# List R1's active content (last year)
./prepopulate-r2.sh list \
  --serverid psblr --sourceRepo sum-cba-npm-remote \
  --downloadedWithin 1y

# Dry-run to see the jf npm pack commands
./prepopulate-r2.sh prepopulate \
  --serverid psblr --targetRepo testpopulate-npm-remote \
  --fromFile npm-artifacts-*.txt --dry-run

# Real run
./prepopulate-r2.sh prepopulate \
  --serverid psblr --targetRepo testpopulate-npm-remote \
  --fromFile npm-artifacts-*.txt
```

**Python (with concurrency):**
```bash
cd python/

python3 prepopulate-r2.py list \
  --serverid psblr --sourceRepo sum-cba-npm-remote \
  --downloadedWithin 1y

python3 prepopulate-r2.py prepopulate \
  --serverid psblr --targetRepo testpopulate-npm-remote \
  --fromFile npm-artifacts-*.txt --concurrency 8
```

## Flags

`list` subcommand:

```
--serverid <id>              JFrog CLI server ID
--sourceRepo <repo>          R1 npm remote name (without -cache suffix)
--downloadedWithin <dur>     AQL filter on stat.downloaded (e.g. 1y, 6mo, 30d)
--createdWithin <dur>        AQL filter on created
```

`prepopulate` subcommand:

```
--serverid <id>              JFrog CLI server ID
--targetRepo <repo>          R2 npm remote to warm
--sourceRepo <repo>          Auto-enumerate from R1 (mutually exclusive with --fromFile)
--fromFile <path>            Read pkg@version list from file (mutually exclusive with --sourceRepo)
--downloadedWithin <dur>     Time filter when using --sourceRepo
--createdWithin <dur>        Additional time filter
--dry-run                    Print jf npm pack commands, do not execute
--verbose, -v                Show trailing error line for FAIL/BLOCK/MISS entries
--concurrency N              Python only: parallel pack workers (default 8)
```

Duration format: `1d`, `1w`, `6mo`, `1y`.

Input file format: one `pkg@version` per line. Lines starting with `#` and blank lines are ignored. Trailing `\r` from Windows-edited files is stripped automatically.

## Coordinate format

```
pkg@version              regular package
@scope/pkg@version       scoped package (e.g. @babel/code-frame@7.29.7)
```

Scoped packages preserve the leading `@` in the pkg name. The parser handles both.

## Output files

- **`npm-artifacts-<pid>.txt`** — output of `list`. One `pkg@version` per line.
- **`prepop-report-<target>-<timestamp>.csv`** — from `prepopulate`. Columns: `pkg_version,status`.

Summary printed at end of `prepopulate`:

```
Summary:
  200    : 487
  403    : 8
  404    : 5
```

## Interpreting results

| Console label | CSV status | Meaning | Action |
|---|---|---|---|
| `OK    [200]` | 200 | Package cached in R2 | Nothing to do |
| `BLOCK [403]` | 403 | Curation policy denied, or auth failed | Review with security team |
| `MISS  [404]` | 404 | Not in upstream (unpublished / renamed) | Feed into rescue-local remediation |
| `FAIL  [---]` | FAIL | Other npm error | Check stderr snippet in report; retry after fixing |

Common FAIL causes:
- `EAUTH` — R2's upstream credentials wrong
- `ETARGET` — pkg exists but requested version doesn't (yanked)
- `ECONNRESET` — network issue, retry
- Rate-limited (rare from registry.npmjs.org, more common from private mirrors)

## Concurrency (Python only)

`--concurrency N` (default 8) enables parallel `jf npm pack` workers. Each worker gets its own scratch subdirectory so multiple concurrent packs don't fight over `.jfrog/projects/npm.yaml` in the same directory. `jf npmc` runs once per worker (lazy setup on first call).

Recommended values:
- npmjs.org (public): `8-16`
- Private Verdaccio / Nexus: `4-8`
- GitHub Packages: `4` (stricter rate limits)

Watch for `429` responses or connection resets — drop concurrency if they appear.

Progress counter `[X/N]` appears on each result line; elapsed time at completion.

## Rescue-local remediation

For entries flagged 404 by [check-upstream](./check-upstream.md):

1. Create an npm rescue local repo (e.g. `<prefix>-npm-rescue-local`).
2. Copy affected `.tgz` files from R1's cache. npm cache layout in Artifactory is `<pkg>/-/<pkg>-<version>.tgz`:
   ```bash
   # For coord "eslint@8.57.0"
   jf rt cp \
     <R1>-cache/eslint/-/eslint-8.57.0.tgz \
     <rescue-local>/eslint/-/eslint-8.57.0.tgz

   # For scoped "@babel/code-frame@7.29.7"
   jf rt cp \
     <R1>-cache/@babel/code-frame/-/code-frame-7.29.7.tgz \
     <rescue-local>/@babel/code-frame/-/code-frame-7.29.7.tgz
   ```
3. Add rescue local to virtual V1 alongside R2, ordered so R2 is checked first with rescue as fallback.

**Trade-off:** Curation only intercepts remotes. Rescue-local artifacts bypass Curation. Compensating controls: Xray still indexes; scope discipline (only confirmed-missing packages); treat as frozen and sunset as pins upgrade.

## Troubleshooting

**`ERROR: 'npm' binary not found on PATH`** — install Node.js: `brew install node` on macOS, or your platform's equivalent. Verify with `npm -v` afterwards.

**All entries return 403** — either Curation is blocking everything (unlikely unless an aggressive policy is in place), or R2's upstream credentials are wrong. Check R2's config:
```bash
jf rt curl "/api/repositories/<targetRepo>" --server-id <id> \
  | jq '{key, rclass, url, packageType, username}'
```

**Sparse 403s** — real Curation policy blocks on those specific packages/versions. Coordinate with security to allowlist or bump pins.

**Scoped packages misparsed** — output looks like `@babel@code-frame@7.29.7` (wrong) instead of `@babel/code-frame@7.29.7`. Old script version bug — current parser handles the `/-/` separator correctly. Regenerate the list.

**`ENOTFOUND` errors** — npm can't reach R2. Check network path and that R2 is up (`jf rt ping --server-id <id>`).

**`jf npmc` command not found** — you have an older jf CLI. The script falls back to `jf npm-config` automatically. If both fail, bump the CLI (`jf update`).

## Related

- [`check-upstream.md`](./check-upstream.md) — companion script for upstream availability checks
- [`README.md`](./README.md) — NPM folder overview and quick-start
- [`python/README.md`](./python/README.md) — Python-specific setup and concurrency notes
- [`../README.md`](../README.md) — top-level index of all package types
