# PyPI scripts — Python port

Python equivalents of the bash scripts in `../` with `ThreadPoolExecutor` concurrency built in.

- `prepopulate-r2-pypi.py` — enumerate R1's cached PyPI artifacts, run `jf pip download --no-deps` per package through R2. Multi-worker with per-worker download dirs.
- `check-upstream-pypi.py` — GET each package's PEP 503 simple index, check for the specific version filename. Concurrent, `--via-r1` mode for corporate-proxy environments (Zscaler).
- `prepop_lib.py` — shared utility library (same file as in `../../Docker/python/`, `../../Maven/python/`, `../../NPM/python/`).

Same CLI flags as the bash originals in the parent folder.

## Prerequisites

- **Python 3.8+**: verify `python3 -V`
- **`requests` library**: `pip install requests` (or `pip3`)
- **JFrog CLI (`jf`)**: `jf --version`
- **`pip` on PATH (not just `pip3`)**: `jf pip download` shells out to a binary literally named `pip`. On macOS the default is `pip3` — you need to create the alias/symlink:
  ```bash
  ln -s /opt/homebrew/bin/pip3 /opt/homebrew/bin/pip   # Homebrew/Apple Silicon
  ln -s $(which pip3) /usr/local/bin/pip                # macOS/system
  alias pip=pip3                                        # add to ~/.zshrc
  ```
  Verify: `pip -V` should print pip version.
- **Configured server ID**: `jf c show <your-serverid>`

Quick sanity check:
```bash
python3 -c "import requests; print('requests', requests.__version__)"
jf c show psblr
pip -V
```

## Quick start

```bash
cd Python/python/

# LIST: enumerate R1's cached pkg==version pairs
python3 prepopulate-r2-pypi.py list \
  --serverid psblr --sourceRepo bmll-new-pypi-remote
# → pypi-artifacts-<timestamp>.txt

# PREPOPULATE: dry-run first
python3 prepopulate-r2-pypi.py prepopulate \
  --serverid psblr --targetRepo testpopulate-pypi-remote \
  --fromFile pypi-artifacts-*.txt --dry-run

# Real run — default concurrency 8
python3 prepopulate-r2-pypi.py prepopulate \
  --serverid psblr --targetRepo testpopulate-pypi-remote \
  --fromFile pypi-artifacts-*.txt

# Higher concurrency for large scans
python3 prepopulate-r2-pypi.py prepopulate \
  --serverid psblr --targetRepo testpopulate-pypi-remote \
  --fromFile pypi-artifacts-*.txt --concurrency 16

# CHECK-UPSTREAM: direct (works when no corporate proxy)
python3 check-upstream-pypi.py \
  --serverid psblr --sourceRepo bmll-new-pypi-remote \
  --fromFile pypi-artifacts-*.txt --concurrency 16

# CHECK-UPSTREAM via R1 (Zscaler / corporate proxy workaround)
python3 check-upstream-pypi.py \
  --serverid psblr --sourceRepo bmll-new-pypi-remote \
  --fromFile pypi-artifacts-*.txt --via-r1 --concurrency 16
```

## Flags

`prepopulate-r2-pypi.py`:
```
list         --serverid --sourceRepo [--downloadedWithin] [--createdWithin]

prepopulate  --serverid --targetRepo
             ( --sourceRepo [--downloadedWithin] [--createdWithin]
             | --fromFile <path> )
             [--dry-run] [--keep-work-dir]
             [--concurrency N] [--verbose]
```

`check-upstream-pypi.py`:
```
--serverid --sourceRepo
( --fromFile <path> | [--downloadedWithin] [--createdWithin] )
[--via-r1] [--connect-timeout <sec>] [--concurrency N] [--verbose]
```

## Concurrency model

**check-upstream-pypi.py** — GETs to the simple index run concurrently. Response body is grep'd for the version filename prefix. `--via-r1` routes through your tenant's PyPI API endpoint when direct upstream is blocked (files.pythonhosted.org auto-swaps to pypi.org for simple-index checks; direct pypi.org gets blocked by Zscaler in some corporate environments).

**prepopulate-r2-pypi.py** — `jf pipc` configures the resolver in CWD once (writes `.jfrog/projects/pip.yaml`). All workers then read this config concurrently (safe — it's read-only during downloads). Each worker downloads to its own per-thread subdirectory to prevent file collisions.

If one worker hits the "pip binary not found" preflight error mid-run, all remaining workers short-circuit and the script hard-exits with a clear fix message (no wasted retries on packages when the tooling itself is broken).

Rough expectations:
- **check-upstream**: 5-10x speedup with concurrency=8 (simple index responses are small and cached at CDN)
- **prepopulate**: 3-5x speedup (each `jf pip download` shells out to pip, network-bound)

## Files created during a prepopulate run

- `.jfrog/projects/pip.yaml` in CWD — jf's pip resolver config. Removed on exit unless `--keep-work-dir` is passed. If `.jfrog/` already existed before the run, only the added `pip.yaml` is removed (your own config is left alone).
- `/tmp/pypi-prepop-<xxx>/` — scratch downloads dir, cleaned up on exit.
- `pypi-prepop-report-<target>-<timestamp>.csv` — the report.

## Troubleshooting

**`ERROR: 'pip -V' failed`** — install pip or symlink. See Prerequisites above.

**Every entry returns 404** — usually a pip prereq issue. The script hard-exits on the first NOPIP error with the fix message. If you see actual 404s but check-upstream shows OK, that's a real state mismatch — worth investigating.

**All 403 (Curation blocked)** — those are legitimate policy denials from your Curation policies. Not a script bug; coordinate with your security team on exceptions or version bumps.

**Rate limiting** — pypi.org rarely rate-limits simple-index requests (heavily CDN-cached). If you hit them anyway, drop `--concurrency`.

**`ModuleNotFoundError: No module named 'requests'`** — `pip install requests`.

## Related

- [`../prepopulate-r2-pypi.sh`](../prepopulate-r2-pypi.sh) — the bash original
- [`../check-upstream-pypi.sh`](../check-upstream-pypi.sh) — bash upstream check
- [`../../Maven/python/`](../../Maven/python/) — Maven Python equivalents
- [`../../Docker/python/`](../../Docker/python/) — Docker Python equivalents
- [`../../NPM/python/`](../../NPM/python/) — NPM Python equivalents
