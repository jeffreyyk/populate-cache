# prepopulate-r2-pypi.sh

PyPI analog of [prepopulate-r2.sh](./README.md). Enumerate PyPI artifacts (`.whl`, `.tar.gz`, `.zip`) in R1's cache, then use `jf pip download` to fetch each pinned version through R2 so R2's cache warms and Curation policies evaluate every artifact.


For detecting artifacts that no longer exist upstream, see [check-upstream-pypi.sh](./check-upstream-pypi.sh).

## What it does

**Two subcommands:**

- **`list`** — AQL enumerates `.whl`, `.tar.gz`, and `.zip` files in R1's cache. jq extracts `pkg==version` from each filename via regex. Handles scoped names (`zope.interface`), dashes (`pkg-with-dashes`), and pre-release versions (`1.0.0.dev1`).
- **`prepopulate`** — Configures a jf pip resolver pointing at R2 (`.jfrog/projects/pip.yaml` in CWD), then runs `jf pip download <pkg>==<version> --no-deps` for each entry. Downloaded files go to a tmp dir and are cleaned up after each entry.


## Prerequisites

**Hard requirement: `pip` (not just `pip3`) must be on PATH.**

`jf pip` shells out to a binary literally named `pip`. On macOS, Python 3.x ships `pip3` but doesn't create a `pip` alias by default. Without one, every download silently fails with `executable file not found`.

Verify:
```bash
pip -V
# Expected output like:  pip 24.0 from /opt/homebrew/lib/... (python 3.12)
```

If `pip3 -V` works but `pip -V` doesn't, create a symlink:
```bash
# Homebrew (Apple Silicon)
ln -s /opt/homebrew/bin/pip3 /opt/homebrew/bin/pip

# System / Intel Homebrew
ln -s "$(which pip3)" /usr/local/bin/pip

# Or alias in shell rc (add to ~/.zshrc or ~/.bashrc)
alias pip=pip3
```

If neither exists:
```bash
python3 -m ensurepip --upgrade
```

**Other prerequisites:**

- `jf` CLI configured with a server ID
- `jq`
- `python3` (any modern version)

Verify:
```bash
jf c show <your-server-id>
which jq python3
pip -V   # this is the critical one
```

## Quick start

```bash
# 1. List R1's active PyPI content (last year)
./prepopulate-r2-pypi.sh list \
  --serverid psblr --sourceRepo pypi-remote \
  --downloadedWithin 1y
# → pypi-artifacts-<pid>.txt

# 2. Dry-run against R2 to see the jf pip download commands
./prepopulate-r2-pypi.sh prepopulate \
  --serverid psblr --targetRepo pypi-remote2 \
  --fromFile pypi-artifacts-<pid>.txt \
  --dry-run

# 3. Real run
./prepopulate-r2-pypi.sh prepopulate \
  --serverid psblr --targetRepo pypi-remote2 \
  --fromFile pypi-artifacts-<pid>.txt
```

## Flag reference

### `list` subcommand

| Flag | Required | Description |
|---|---|---|
| `--serverid <id>` | yes | JFrog CLI server ID |
| `--sourceRepo <name>` | yes | R1 PyPI remote name (without `-cache` suffix) |
| `--downloadedWithin <dur>` | no | Include only items downloaded within this window |
| `--createdWithin <dur>` | no | Include only items created within this window |

### `prepopulate` subcommand

| Flag | Required | Description |
|---|---|---|
| `--serverid <id>` | yes | JFrog CLI server ID |
| `--targetRepo <name>` | yes | R2 PyPI remote to warm |
| `--sourceRepo <name>` | one of | Enumerate R1 via AQL as the source list |
| `--fromFile <path>` | one of | Read `pkg==version` list from a file |
| `--downloadedWithin <dur>` | no | Time filter when using `--sourceRepo` |
| `--createdWithin <dur>` | no | Time filter when using `--sourceRepo` |
| `--dry-run` | no | Print commands, do not execute |
| `--keep-work-dir` | no | Preserve `.jfrog/projects/pip.yaml` and downloads on exit (for debugging) |

**Duration format**: `1d`, `1w`, `6mo`, `1y`.

**Input file format**: one `pkg==version` per line. Lines starting with `#` and blank lines are ignored. Trailing `\r` from Windows-edited files is stripped automatically.

## Resolver config location

`prepopulate` creates `.jfrog/projects/pip.yaml` in your **current working directory** (not a temp dir). This makes it easy to inspect what jf pipc configured:

```bash
cat .jfrog/projects/pip.yaml
```

Expected content:
```yaml
version: 1
type: pip
resolver:
    repo: pypi-remote2
    serverId: psblr
```

The script overrides any existing pip.yaml at that path (logging the previous resolver for visibility), so switching between R2 repos in successive runs works cleanly. On exit, the file is removed unless `--keep-work-dir` is passed. If `.jfrog/` didn't exist before the script ran, the whole directory is cleaned up; if it did (from your own jf CLI setup), only the pip.yaml the script added is removed.

## Output files

- **`pypi-artifacts-<pid>.txt`** — output of `list`, or intermediate from `prepopulate --sourceRepo`. One `pkg==version` per line.
- **`pypi-prepop-report-<target>-<timestamp>.csv`** — from `prepopulate`. Columns: `pkg_version,status`.

Summary printed at end of `prepopulate`:

```
Summary:
  200    : 10
  403    : 3
```

## Interpreting results

| Status | Label | Meaning | Action |
|---|---|---|---|
| 200 | `OK` | Simple index + artifact warmed in R2's cache | Nothing to do |
| 403 | `BLOCK` | Curation policy denied this package/version | Review with security team; may need policy exception or version bump |
| 404 | `MISS` | Not in upstream (yanked or removed) | Feed into rescue-local remediation |
| FAIL | `FAIL` | Other error — pip issue, network, unexpected format | See error snippet in report; retry after fixing |

The classification uses `pip` stderr patterns:
- `no matching distribution` / `could not find a version` → 404
- `401` / `403` / `forbidden` / `unauthorized` → 403
- `executable file not found` → aborts the whole run with the `pip` install hint (this is a prerequisite failure, not a per-package problem)

## Rescue-local remediation

For entries flagged 404 (or 403, if the policy block is a genuine "we can't ship this to R2" decision):

1. Create a rescue local repo (e.g. `<prefix>-pypi-rescue-local`).
2. Copy the affected artifacts from `R1-cache` into the rescue local. PyPI cache layout in Artifactory is typically flat by package name:
   ```bash
   jf rt cp <R1>-cache/<pkg-normalized>/ <rescue-local>/<pkg-normalized>/ --recursive
   ```
3. Add the rescue local to virtual V1 alongside R2, ordered so R2 is checked first with rescue as fallback.

**Trade-off:** Curation only intercepts remotes. Artifacts in a local repo bypass Curation. Compensating controls: Xray still indexes; scope discipline (only confirmed-missing / confirmed-approved-exception packages); treat as frozen and sunset as pins are upgraded.


