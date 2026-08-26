# Maven — R1 → R2 migration scripts

Bash and Python scripts to enumerate a source Maven remote (R1), pre-populate the target Curation-enabled remote (R2), and check what still exists upstream.

- `prepopulate-r2-maven.sh` / `python/prepopulate-r2-maven.py` — list R1's cached coords, then HEAD each `.jar` and `.pom` through R2 to warm the cache and trigger Curation.
- `check-upstream-maven.sh` / `python/check-upstream-maven.py` — HEAD each coord directly against upstream (usually Maven Central) to distinguish "gone from upstream" from "gone from R1".

Bash and Python are functionally equivalent — same CLI flags, same output shape (CSV columns, log format), same behavior. Python adds `--concurrency N` for parallel HEAD requests.

## Prerequisites

- **`jf` CLI** — configured with a server ID. Verify: `jf c show <serverid>`
- **`jq` and `curl`** — on PATH. Verify: `which jq curl`
- **Python 3.8+** (Python mode only) — `python3 -V`
- **`requests` library** (Python mode only) — `pip install requests`

Quick sanity check:

```bash
jf c show psblr
which jq curl
python3 -c "import requests; print('requests', requests.__version__)"   # Python mode
```

## Quick start (bash)

```bash
# --- LIST: enumerate R1's cached coordinates ---
./prepopulate-r2-maven.sh list \
  --serverid psblr --sourceRepo sum-cba-maven-remote
# → maven-artifacts-<timestamp>.txt

# --- PREPOPULATE: dry-run first to see what would be HEAD'd ---
./prepopulate-r2-maven.sh prepopulate \
  --serverid psblr --targetRepo testpopulate-maven \
  --fromFile maven-artifacts-*.txt --dry-run

# --- Real run ---
./prepopulate-r2-maven.sh prepopulate \
  --serverid psblr --targetRepo testpopulate-maven \
  --fromFile maven-artifacts-*.txt

# --- CHECK-UPSTREAM: verify which coords still exist on upstream ---
./check-upstream-maven.sh \
  --serverid psblr --sourceRepo sum-cba-maven-remote \
  --fromFile maven-artifacts-*.txt
```

## Quick start (Python, with concurrency)

```bash
cd python/

# --- LIST ---
python3 prepopulate-r2-maven.py list \
  --serverid psblr --sourceRepo sum-cba-maven-remote

# --- PREPOPULATE: dry-run ---
python3 prepopulate-r2-maven.py prepopulate \
  --serverid psblr --targetRepo testpopulate-maven \
  --fromFile maven-artifacts-*.txt --dry-run

# --- Real run, concurrent ---
python3 prepopulate-r2-maven.py prepopulate \
  --serverid psblr --targetRepo testpopulate-maven \
  --fromFile maven-artifacts-*.txt --concurrency 8

# --- CHECK-UPSTREAM, concurrent ---
python3 check-upstream-maven.py \
  --serverid psblr --sourceRepo sum-cba-maven-remote \
  --fromFile maven-artifacts-*.txt --concurrency 8
```

## Coordinate format

```
groupId:artifactId:version               regular artifact (fetch .jar + .pom)
groupId:artifactId:version:pom           POM-only (BOMs, parent poms) — .pom only
```

The `:pom` suffix is added automatically by `list` when R1's cache only contains a `.pom`. Prepopulate and check-upstream respect it and skip the `.jar` HEAD for those.

## Concurrency (Python only)

Both Python scripts accept `--concurrency N` (default 8). HEAD requests are I/O-bound and gain 5-10x speedup with `--concurrency 8`. Results appear in completion order (not input order) — normal for concurrent code. A progress counter `[X/N]` is on each result line, and the elapsed time is printed at completion.

Recommended `--concurrency`:
- Maven Central: `8-16`
- Sonatype OSS: `4-8`
- Private Nexus / Artifactory: `4-8` (respect internal infra)

If you see `429` responses or connection resets, drop the concurrency.

## Reference

- [`prepopulate-r2-maven.md`](./prepopulate-r2-maven.md) — full prepopulate details
- [`check-upstream-maven.md`](./check-upstream-maven.md) — full check-upstream details
- [`python/README.md`](./python/README.md) — Python-specific setup notes
- [`../README.md`](../README.md) — top-level index of all package types