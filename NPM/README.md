# prepopulate-r2

Warm a new npm smart remote (**R2**) from an existing remote's cache (**R1**) using `jf npm pack`, so Curation policies evaluate every artifact and R2's cache is ready before cutover.

Built for the R1 → R2 migration pattern where an old uncurated remote is being replaced by a new curated one inside the same virtual repository. The script enumerates the tarballs R1 has been serving, then for each entry runs `jf npm pack <pkg>@<version>` through R2 — which fetches the metadata document, evaluates it through Curation, downloads the pinned-version tarball, and populates R2's cache exactly like a real developer install would (minus the dependency-tree expansion).

For detecting artifacts that no longer exist upstream (the input to the rescue-local remediation step), see [check-upstream.md](./check-upstream.md).

For Docker repositories, see [prepopulate-r2-docker.md](./prepopulate-r2-docker.md).

## What it does

**Two subcommands:**

- **`list`** — Enumerate `.tgz` tarballs in R1's cache via AQL. Optional time filters (`--downloadedWithin`, `--createdWithin`) narrow the list to recent activity. Output is one `pkg@version` per line.
- **`prepopulate`** — Read the list (either freshly generated from R1 or from `--fromFile`) and for each entry run `jf npm pack <pkg>@<version>` through R2. Reports 200 / 403 / 404 / FAIL per entry.

## Why `jf npm pack`

Three candidates were considered for the pre-population trigger:

| Approach | Populates tarball | Populates `.npm/` metadata | Pulls transitive deps | Speed |
|---|---|---|---|---|
| `curl HEAD` on tarball URL | ✅ | ❌ | — | Fastest |
| `jf npm install` | ✅ | ✅ | ✅ (over-populates R2) | Slowest |
| `jf npm pack` | ✅ | ✅ | ❌ | Middle |

`jf npm pack` is the sweet spot: it hits both endpoints Artifactory needs to populate a complete cache entry (metadata document under `.npm/<pkg>/package.json`, tarball under `<repo>/<pkg>/-/<pkg>-<version>.tgz`), but it does not resolve dependencies. So R2 ends up with exactly the same entries R1 had — no more, no less.

Under the hood the script:

1. Creates a scratch directory (`mktemp -d`).
2. Runs `jf npmc --repo-resolve <targetRepo> --server-id-resolve <serverid>` inside it. Falls back to `jf npm-config` on newer CLI versions. This writes `.jfrog/projects/npm.yaml` so all subsequent `jf npm` commands route through R2.
3. For each `pkg@version` in the input list, runs `jf npm pack <pkg>@<version>` from the scratch dir. jf CLI handles auth, resolver config, and the actual npm invocation.
4. Deletes the `.tgz` file that `npm pack` writes into the scratch dir after each run (otherwise disk fills up).
5. Cleans up the scratch dir on exit via EXIT trap. `--keep-work-dir` preserves it for debugging.

## Prerequisites

- `jf` CLI configured with a server ID.
- `jq` for JSON parsing.
- `npm` (Node.js) — used under the hood by `jf npm`.

Verify:

```bash
jf c show <your-server-id>
which jq npm
```

## Quick start

```bash
# 1. List R1's active set (last year)
./prepopulate-r2.sh list \
  --serverid sum2 --sourceRepo npm-remote \
  --downloadedWithin 1y
# → artifacts-<pid>.txt   (one pkg@version per line)

# 2. Dry-run against R2 to see the jf npm pack commands
./prepopulate-r2.sh prepopulate \
  --serverid sum2 --targetRepo npm-remote2 \
  --fromFile artifacts-<pid>.txt \
  --dry-run

# 3. Real run
./prepopulate-r2.sh prepopulate \
  --serverid sum2 --targetRepo npm-remote2 \
  --fromFile artifacts-<pid>.txt
```

## Flag reference

### `list` subcommand

| Flag | Required | Description |
|---|---|---|
| `--serverid <id>` | yes | JFrog CLI server ID |
| `--sourceRepo <name>` | yes | R1 remote name (without `-cache` suffix) |
| `--downloadedWithin <dur>` | no | Include only items downloaded within this window |
| `--createdWithin <dur>` | no | Include only items created within this window |

### `prepopulate` subcommand

| Flag | Required | Description |
|---|---|---|
| `--serverid <id>` | yes | JFrog CLI server ID |
| `--targetRepo <name>` | yes | R2 remote name to warm |
| `--sourceRepo <name>` | one of | Enumerate R1 via AQL as the source list |
| `--fromFile <path>` | one of | Read `pkg@version` list from a file |
| `--downloadedWithin <dur>` | no | Time filter when using `--sourceRepo` |
| `--createdWithin <dur>` | no | Time filter when using `--sourceRepo` |
| `--dry-run` | no | Print commands, do not execute |
| `--keep-work-dir` | no | Preserve the scratch npm work dir on exit (for debugging) |

**Duration format**: `1d`, `1w`, `6mo`, `1y`.

**Input file format**: one `pkg@version` per line. Lines starting with `#` and blank lines are ignored. Trailing `\r` from Windows-edited files is stripped automatically.

## Output files

- **`artifacts-<pid>.txt`** — output of `list`, or intermediate from `prepopulate --sourceRepo`. One `pkg@version` per line.
- **`prepop-report-<target>-<timestamp>.csv`** — from `prepopulate`. Columns: `pkg_version,status`.

Summary printed at the end of `prepopulate`:

```
200    : 847
403    :   3
404    :  12
FAIL   :   1
```

## Interpreting results

| Status | Label | Meaning | Action |
|---|---|---|---|
| 200 | `OK` | Tarball and metadata warmed in R2 | Nothing to do. |
| 403 | `BLOCK` | Curation policy denied, or upstream auth failed | Review with security. Distinguish Curation-denied from auth failures via the report row and jf/npm error message. |
| 404 | `MISS` | Not in upstream | Feed into rescue-local remediation. |
| FAIL | `FAIL` | Other error — network, jf CLI, resolver misconfig | See error snippet in report; retry after fixing. |

The classification is heuristic — it greps `jf npm pack` stderr for known error strings (`404`, `not found`, `unauthorized`, `EAUTH`, etc.). Some obscure errors may fall into `FAIL` where a more specific label would be nicer.

## Rescue-local remediation

For entries flagged 404 (in the report or by [check-upstream](./check-upstream.md)):

1. Create a rescue local repo per package type (e.g. `<prefix>-npm-rescue-local`).
2. Copy the affected tarballs from `R1-cache` into the rescue local:
   ```bash
   jf rt cp <R1>-cache/<path> <rescue-local>/<path>
   ```
3. Add the rescue local to virtual V1 alongside R2, ordered so R2 is checked first with rescue local as fallback.

**Trade-off:** Curation only intercepts remote fetches. Artifacts in a local repo bypass Curation for the lifetime of the copy. Compensating controls: Xray still indexes the local repo; scope discipline (only confirmed-missing artifacts, not bulk R1 copies); treat the rescue local as frozen and sunset it as pins are upgraded.

## Troubleshooting

**`ERROR: server ID '<id>' not configured`** — Run `jf c add`, or verify with `jf c show`.

**`ERROR: could not configure jf npm resolver`** — Neither `jf npmc` nor `jf npm-config` accepted the args on your CLI version. Check `jf --version` and run `jf <cmd> --help` to see the current syntax; may need to bump jf CLI.

**`ERROR: 'npm' binary not found on PATH`** — Install Node.js. `jf npm pack` shells out to real `npm` under the hood.

**Statuses all come back as `FAIL`** — Rerun with `--keep-work-dir` and inspect the scratch dir manually:
```bash
./prepopulate-r2.sh prepopulate ... --keep-work-dir
# Note the "Scratch dir preserved: /tmp/tmp.XXXX" line
cd /tmp/tmp.XXXX
jf npm pack eslint@8.57.0    # try one manually to see the real error
```

**Docker repos** — This script is npm-only. For Docker, see [prepopulate-r2-docker.md](./prepopulate-r2-docker.md).

## Related

- **[check-upstream.md](./check-upstream.md)** — companion script to detect artifacts removed from upstream.
- **[prepopulate-r2-docker.md](./prepopulate-r2-docker.md)** — Docker analog using `docker pull`.
- **Cleanup script** (`CleanupScriptWithConditions.sh`) — inverse operation: delete artifacts by AQL criteria.

## License

Internal PS tool. No external distribution.
