# Maven scripts — Python port

Python equivalents of the bash scripts in `../`:

- `prepopulate-r2-maven.py` — enumerate R1's cached Maven artifacts, HEAD each through R2 to warm the cache and trigger Curation.
- `check-upstream-maven.py` — HEAD each Maven coordinate directly against upstream to determine what's still there vs. genuinely missing.
- `prepop_lib.py` — shared utility library (imported by the two scripts above; also duplicated in `../../Docker/python/` for self-containment).

Same CLI flags as the bash originals in the parent folder, same output shape (CSV columns, log format), same behavior. You can swap `.sh` for `.py` in cron jobs or wrappers without changing anything else.

## Prerequisites

- **Python 3.8+** — uses dataclasses. Verify: `python3 -V`
- **`requests` library** — for HTTP calls. Install: `pip install requests` (or `pip3`)
- **JFrog CLI (`jf`)** — same as bash version; the Python scripts shell out to `jf` for AQL search and config export. Verify: `jf --version`
- **A configured server ID** — same as bash. Verify: `jf c show <your-serverid>`

Quick sanity check that everything's in place:

```bash
python3 -c "import requests; print('requests', requests.__version__)"
jf c show psblr
```

## Quick start

```bash
cd Maven/python/

# --- LIST: enumerate R1's cached coordinates ---
python3 prepopulate-r2-maven.py list \
  --serverid psblr --sourceRepo testpopulate-maven
# → maven-artifacts-<timestamp>.txt

# --- PREPOPULATE: dry-run first to see what would be HEAD'd ---
python3 prepopulate-r2-maven.py prepopulate \
  --serverid psblr --targetRepo testpopulate-maven2 \
  --fromFile maven-artifacts-*.txt --dry-run

# --- Real run ---
python3 prepopulate-r2-maven.py prepopulate \
  --serverid psblr --targetRepo testpopulate-maven2 \
  --fromFile maven-artifacts-*.txt

# --- CHECK-UPSTREAM: verify which coords still exist on upstream ---
python3 check-upstream-maven.py \
  --serverid psblr --sourceRepo testpopulate-maven \
  --fromFile maven-artifacts-*.txt

# --- Verbose mode adds per-file timing ---
python3 prepopulate-r2-maven.py prepopulate \
  --serverid psblr --targetRepo testpopulate-maven2 \
  --fromFile maven-artifacts-*.txt -v
```

## Flags (identical to bash version)

`prepopulate-r2-maven.py`:

```
list         --serverid --sourceRepo [--downloadedWithin] [--createdWithin]
             [--includeSources] [--includeJavadoc]

prepopulate  --serverid --targetRepo
             ( --sourceRepo [--downloadedWithin] [--createdWithin]
             | --fromFile <path> )
             [--includeSources] [--includeJavadoc]
             [--withMetadata] [--dry-run] [--verbose]
             [--connect-timeout <sec>]
```

`check-upstream-maven.py`:

```
--serverid --sourceRepo
( --fromFile <path> | [--downloadedWithin] [--createdWithin] )
[--connect-timeout <sec>] [--verbose]
```

Duration format for `--downloadedWithin`/`--createdWithin`: `1d`, `1w`, `6mo`, `1y`.

See the top-level docs in `../` for full flag semantics and output shape:
- [`../prepopulate-r2-maven.md`](../prepopulate-r2-maven.md)
- [`../check-upstream-maven.md`](../check-upstream-maven.md)

Everything documented there applies to these Python versions too — the CLI is the same.