# prepopulate-r2-pypi

Enumerate the PyPI artifacts in R1's cache and run `jf pip download --no-deps` for each one through R2 to warm R2's cache and trigger Curation policies. Available as both a bash script (`prepopulate-r2-pypi.sh`) and a Python port (`python/prepopulate-r2-pypi.py`) with concurrency.

Same behavior, same output — pick bash for zero-setup, Python for parallel downloads.

## What it does

- **`list`** — AQL search over R1's cache for `.whl`, `.tar.gz`, and `.zip` files. Parses `<pkg>-<version>.<ext>` and emits `pkg==version` per line.
- **`prepopulate`** — Configures the jf pip resolver against R2 (writes `.jfrog/projects/pip.yaml` in CWD), then for each entry runs `jf pip download pkg==version --no-deps -d <tmp>`. `--no-deps` avoids pulling transitive dependencies (which would over-populate).

## Why `jf pip download` (not curl GET)

PyPI has a metadata protocol (PEP 503 simple index) that direct GET doesn't warm consistently across all pip versions. Curl GET on the wheel URL populates the artifact but leaves the simple index cold — subsequent `pip install` calls would still hit upstream for metadata. `jf pip download` invokes pip's real resolver against R2, hitting both endpoints without side effects (no install, no deps with `--no-deps`).

## Prerequisites

- **`jf` CLI** — configured with a server ID. Verify: `jf c show <serverid>`
- **`jq`** — on PATH
- **`pip` binary on PATH (not just `pip3`)** — `jf pip download` shells out to a binary literally named `pip`. On macOS the default is `pip3` — you need an alias or symlink:
  ```bash
  ln -s /opt/homebrew/bin/pip3 /opt/homebrew/bin/pip   # Homebrew macOS/Apple Silicon
  ln -s $(which pip3) /usr/local/bin/pip                # macOS/system
  alias pip=pip3                                        # add to ~/.zshrc
  ```
  Verify: `pip -V` (should print pip version).
- **Python 3.8+ and `requests`** (Python mode only) — `pip install requests`

## Quick start

**Bash:**
```bash
# List R1's active content (last year)
./prepopulate-r2-pypi.sh list \
  --serverid psblr --sourceRepo sum-cba-pypi-remote \
  --downloadedWithin 1y

# Dry-run to see the jf pip download commands
./prepopulate-r2-pypi.sh prepopulate \
  --serverid psblr --targetRepo testpopulate-pypi-remote \
  --fromFile pypi-artifacts-*.txt --dry-run

# Real run
./prepopulate-r2-pypi.sh prepopulate \
  --serverid psblr --targetRepo testpopulate-pypi-remote \
  --fromFile pypi-artifacts-*.txt
```

**Python (with concurrency):**
```bash
cd python/

python3 prepopulate-r2-pypi.py list \
  --serverid psblr --sourceRepo sum-cba-pypi-remote \
  --downloadedWithin 1y

python3 prepopulate-r2-pypi.py prepopulate \
  --serverid psblr --targetRepo testpopulate-pypi-remote \
  --fromFile pypi-artifacts-*.txt --concurrency 8
```

## Flags

`list` subcommand:

```
--serverid <id>              JFrog CLI server ID
--sourceRepo <repo>          R1 PyPI remote name (without -cache suffix)
--downloadedWithin <dur>     AQL filter on stat.downloaded (e.g. 1y, 6mo, 30d)
--createdWithin <dur>        AQL filter on created
```

`prepopulate` subcommand:

```
--serverid <id>              JFrog CLI server ID
--targetRepo <repo>          R2 PyPI remote to warm
--sourceRepo <repo>          Auto-enumerate from R1 (mutually exclusive with --fromFile)
--fromFile <path>            Read pkg==version list from file (mutually exclusive with --sourceRepo)
--downloadedWithin <dur>     Time filter when using --sourceRepo
--createdWithin <dur>        Additional time filter
--dry-run                    Print jf pip download commands, do not execute
--keep-work-dir              Preserve .jfrog/projects/pip.yaml and downloads dir on exit
--verbose, -v                Show trailing error line for FAIL/BLOCK/MISS entries
--concurrency N              Python only: parallel download workers (default 8)
```

Duration format: `1d`, `1w`, `6mo`, `1y`.

Input file format: one `pkg==version` per line. Lines starting with `#` and blank lines are ignored. Trailing `\r` from Windows-edited files is stripped automatically.

## Coordinate format

```
pkg==version                 pinned version — the only form supported
```

Examples:
```
requests==2.31.0
urllib3==2.0.4
numpy==1.24.3
```

No wildcards, no version ranges — `pip download --no-deps pkg==version` requires an exact pin. The `list` output only emits exact pins from R1's cached artifact filenames.

## Output files

- **`pypi-artifacts-<pid>.txt`** — output of `list`. One `pkg==version` per line.
- **`pypi-prepop-report-<target>-<timestamp>.csv`** — from `prepopulate`. Columns: `pkg_version,status`.
- **`.jfrog/projects/pip.yaml`** — pip resolver config, written in CWD. Removed on exit unless `--keep-work-dir`.
- **`/tmp/pypi-prepop-<xxx>/`** — scratch downloads dir. Cleaned on exit.

Summary printed at end of `prepopulate`:

```
Summary:
  200    : 487
  403    : 5
  404    : 8
```

## Interpreting results

| Console label | CSV status | Meaning | Action |
|---|---|---|---|
| `OK    [200]` | 200 | Package cached in R2 | Nothing to do |
| `BLOCK [403]` | 403 | Curation policy denied, or auth failed | Review with security team |
| `MISS  [404]` | 404 | Not in upstream (unpublished / yanked) | Feed into rescue-local remediation |
| `FAIL  [---]` | FAIL | Other pip error | Check stderr snippet; retry after fixing |

Common FAIL causes:
- `No matching distribution` — pkg exists but requested version doesn't (yanked)
- `Could not find a version` — pkg or version not on upstream
- `401 Unauthorized` — R2's upstream credentials wrong
- Network / TLS errors — retry

## Concurrency (Python only)

`--concurrency N` (default 8) enables parallel `jf pip download` workers. All workers share the read-only `.jfrog/projects/pip.yaml` config, but each worker downloads to its own per-thread subdirectory to prevent file collisions.

If one worker hits the "pip binary not found" preflight error mid-run, all remaining workers short-circuit and the script hard-exits with a clear fix message rather than N misleading errors.

Recommended values:
- pypi.org (public): `8-16`
- Private Devpi / Nexus: `4-8`
- Internal PyPI mirror: `4-8`

Watch for `429` responses or connection resets — drop concurrency if they appear.

Progress counter `[X/N]` appears on each result line; elapsed time at completion.

## Rescue-local remediation

For entries flagged 404 by [check-upstream-pypi](./check-upstream-pypi.md):

1. Create a PyPI rescue local repo (e.g. `<prefix>-pypi-rescue-local`).
2. Copy affected artifacts from R1's cache. PyPI cache layout in Artifactory keeps files under `<pkg>/<filename>`:
   ```bash
   # For coord "requests==2.31.0"
   jf rt cp \
     "<R1>-cache/requests/requests-2.31.0-py3-none-any.whl" \
     "<rescue-local>/requests/requests-2.31.0-py3-none-any.whl"

   jf rt cp \
     "<R1>-cache/requests/requests-2.31.0.tar.gz" \
     "<rescue-local>/requests/requests-2.31.0.tar.gz"
   ```
   You may need both the wheel and sdist depending on which one pip resolves. Check R1's cache first:
   ```bash
   jf rt curl "/api/search/artifact?name=requests-2.31.0&repos=<R1>-cache" --server-id <id>
   ```
3. Add rescue local to virtual V1 alongside R2, ordered so R2 is checked first with rescue as fallback.

**Trade-off:** Curation only intercepts remotes. Rescue-local artifacts bypass Curation. Compensating controls: Xray still indexes; scope discipline (only confirmed-missing packages); treat as frozen and sunset as pins upgrade.

## Troubleshooting

**`ERROR: 'pip -V' failed`** — the #1 issue on macOS. `jf pip download` shells out to a binary literally named `pip`, but Homebrew installs it as `pip3`. Fix:
```bash
ln -s /opt/homebrew/bin/pip3 /opt/homebrew/bin/pip   # Homebrew macOS
# OR add to ~/.zshrc:
alias pip=pip3
```
Verify with `pip -V` afterwards. Script has a preflight that catches this early and hard-exits with the fix message, so you won't waste time on N failed downloads.

**Every entry returns 404 despite check-upstream showing OK** — likely a `pip.yaml` override issue. If you ran prepopulate against a different R2 previously, an old `.jfrog/projects/pip.yaml` may still be pinning to that. Current script forces override of existing pip.yaml with a "previous resolver was X" log line. If you see something unexpected there, check R2's config.

**All entries return 403** — either Curation is blocking everything, or R2's upstream credentials are wrong. Check R2's config:
```bash
jf rt curl "/api/repositories/<targetRepo>" --server-id <id> \
  | jq '{key, rclass, url, packageType, username}'
```

**Sparse 403s** — real Curation policy blocks on those specific packages/versions. Coordinate with security to allowlist or bump pins.

**`jf pipc` command not found** — you have an older jf CLI. The script falls back to `jf pip-config` automatically. If both fail, bump the CLI (`jf update`).

## Related

- [`check-upstream-pypi.md`](./check-upstream-pypi.md) — companion script for upstream availability checks
- [`README.md`](./README.md) — PyPI folder overview and quick-start
- [`python/README.md`](./python/README.md) — Python-specific setup and concurrency notes
- [`../README.md`](../README.md) — top-level index of all package types
