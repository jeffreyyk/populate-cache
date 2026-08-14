# Docker scripts — Python port

Python equivalents of the bash scripts in `../`:

- `prepopulate-r2-docker.py` — enumerate R1's cached Docker tags, fetch fat manifests, cross-reference cached digests, and `jf docker pull --platform` each entry through R2.
- `check-upstream-docker.py` — direct-upstream HEAD with Docker Registry v2 bearer-challenge auth; `--via-r1` fallback for corporate-proxy environments (Zscaler).
- `prepop_lib.py` — shared utility library (imported by the two scripts above; also duplicated in `../../Maven/python/` for self-containment).

Same CLI flags as the bash originals in the parent folder, same output shape, same behavior. Swap `.sh` for `.py` in your wrappers without changing anything else.

## Prerequisites

- **Python 3.8+** — uses dataclasses. Verify: `python3 -V`
- **`requests` library** — for HTTP calls. Install: `pip install requests` (or `pip3`)
- **JFrog CLI (`jf`)** — used for AQL search, config export, and `jf docker pull`. Verify: `jf --version`
- **Docker daemon** — `jf docker pull` shells out to real `docker` under the hood. Verify: `docker version`
- **A configured server ID** — same as bash. Verify: `jf c show <your-serverid>`

Quick sanity check:

```bash
python3 -c "import requests; print('requests', requests.__version__)"
jf c show psblr
docker version >/dev/null && echo "docker OK"
```

## Quick start

```bash
cd Docker/python/

# --- LIST: enumerate R1's cached tags with per-arch coverage ---
python3 prepopulate-r2-docker.py list \
  --serverid psblr --sourceRepo bmc-docker-remote
# → docker-tags-<timestamp>.txt

# --- PREPOPULATE: dry-run first to see the jf docker pull commands ---
python3 prepopulate-r2-docker.py prepopulate \
  --serverid psblr --targetRepo testpopulate-docker \
  --fromFile docker-tags-*.txt --dry-run

# --- Real run ---
python3 prepopulate-r2-docker.py prepopulate \
  --serverid psblr --targetRepo testpopulate-docker \
  --fromFile docker-tags-*.txt

# --- CHECK-UPSTREAM: direct (works when no proxy is intercepting) ---
python3 check-upstream-docker.py \
  --serverid psblr --sourceRepo bmc-docker-remote \
  --fromFile docker-tags-*.txt

# --- CHECK-UPSTREAM via R1 (Zscaler / corporate proxy workaround) ---
python3 check-upstream-docker.py \
  --serverid psblr --sourceRepo bmc-docker-remote \
  --fromFile docker-tags-*.txt --via-r1
```

## Flags (identical to bash version)

`prepopulate-r2-docker.py`:

```
list         --serverid --sourceRepo [--createdWithin] [--verbose]

prepopulate  --serverid --targetRepo
             ( --sourceRepo [--createdWithin]
             | --fromFile <path> )
             [--registryHost <host>] [--keep-local]
             [--dry-run] [--verbose]
```

`check-upstream-docker.py`:

```
--serverid --sourceRepo
( --fromFile <path> | [--createdWithin] )
[--upstreamUser <u> --upstreamPassword <p>]
[--upstreamAuthToken <t>]
[--via-r1]
[--connect-timeout <sec>] [--verbose]
```

Duration format: `1d`, `1w`, `6mo`, `1y`.

See the docs in `../` for full flag semantics and output shape:
- [`../prepopulate-r2-docker.md`](../prepopulate-r2-docker.md)
- [`../check-upstream-docker.md`](../check-upstream-docker.md)

Everything documented there applies to these Python versions too.