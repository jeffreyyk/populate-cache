# prepopulate-r2-maven

Enumerate the Maven artifacts in R1's cache and HEAD each one through R2 to warm R2's cache and trigger Curation policies. Available as both a bash script (`prepopulate-r2-maven.sh`) and a Python port (`python/prepopulate-r2-maven.py`) with concurrency.

Same behavior, same output — pick bash for zero-setup, Python for parallel HEADs.

## What it does

- **`list`** — AQL search over R1's cache for `.jar` and `.pom` files. Groups by `g:a:v`; emits `g:a:v` for regular artifacts and `g:a:v:pom` for POM-only (BOMs, parent poms).
- **`prepopulate`** — For each coord, HEADs `<R2>/<groupPath>/<artifactId>/<version>/<artifactId>-<version>.jar` (and `.pom`) using auth pulled once from `jf c export`. R2 fetches from upstream, Curation evaluates, cache populates.

## Prerequisites

- **`jf` CLI** — configured with a server ID. Verify: `jf c show <serverid>`
- **`jq` and `curl`** — on PATH
- **Python 3.8+ and `requests`** (Python mode only) — `pip install requests`

## Quick start

**Bash:**
```bash
# List R1's active content (last year)
./prepopulate-r2-maven.sh list \
  --serverid psblr --sourceRepo sum-cba-maven-remote \
  --downloadedWithin 1y

# Dry-run to see the HEAD URLs
./prepopulate-r2-maven.sh prepopulate \
  --serverid psblr --targetRepo testpopulate-maven \
  --fromFile maven-artifacts-*.txt --dry-run

# Real run
./prepopulate-r2-maven.sh prepopulate \
  --serverid psblr --targetRepo testpopulate-maven \
  --fromFile maven-artifacts-*.txt
```

**Python (with concurrency):**
```bash
cd python/

python3 prepopulate-r2-maven.py list \
  --serverid psblr --sourceRepo sum-cba-maven-remote \
  --downloadedWithin 1y

python3 prepopulate-r2-maven.py prepopulate \
  --serverid psblr --targetRepo testpopulate-maven \
  --fromFile maven-artifacts-*.txt --concurrency 8
```

## Flags

`list` subcommand:

```
--serverid <id>              JFrog CLI server ID
--sourceRepo <repo>          R1 Maven remote name (without -cache suffix)
--downloadedWithin <dur>     AQL filter on stat.downloaded (e.g. 1y, 6mo, 30d)
--createdWithin <dur>        AQL filter on created
--includeSources             Include -sources.jar (default: exclude)
--includeJavadoc             Include -javadoc.jar (default: exclude)
```

`prepopulate` subcommand:

```
--serverid <id>              JFrog CLI server ID
--targetRepo <repo>          R2 Maven remote to warm
--sourceRepo <repo>          Auto-enumerate from R1 (mutually exclusive with --fromFile)
--fromFile <path>            Read coord list from file (mutually exclusive with --sourceRepo)
--downloadedWithin <dur>     Time filter when using --sourceRepo
--createdWithin <dur>        Additional time filter
--includeSources             Include -sources.jar
--includeJavadoc             Include -javadoc.jar
--withMetadata               Also HEAD maven-metadata.xml per artifact
--dry-run                    Print URLs, do not execute
--verbose, -v                Per-file phase timing (dns/tls/ttfb/total in bash; elapsed+total in python)
--connect-timeout <sec>      TCP+TLS connect timeout (default 10s)
--concurrency N              Python only: parallel HEAD workers (default 8)
```

Duration format: `1d`, `1w`, `6mo`, `1y`.

Input file format: one coord per line. Lines starting with `#` and blank lines are ignored. Trailing `\r` from Windows-edited files is stripped automatically.

## Coordinate format

```
groupId:artifactId:version           regular artifact (fetch .jar + .pom)
groupId:artifactId:version:pom       POM-only (BOMs, parent poms) — .pom only
```

The `:pom` suffix is added automatically by `list` when R1's cache only contains a `.pom` (no companion `.jar`). Prepopulate reads it and skips the `.jar` HEAD.

## Output files

- **`maven-artifacts-<pid>.txt`** — output of `list`. One coord per line.
- **`maven-prepop-report-<target>-<timestamp>.csv`** — from `prepopulate`. Columns: `coord,artifact_type,http_status`. One row per file (regular coord = 2 rows for jar+pom; BOM = 1 row for pom).

Summary printed at end of `prepopulate`:

```
Summary (by artifact_type + status):
  jar/200      : 823
  jar/404      : 3
  pom/200      : 845
  pom/404      : 3
```

## Interpreting results

| Console label | CSV status | Meaning | Action |
|---|---|---|---|
| `OK    [200]` | 200 | Artifact reachable and cached in R2 | Nothing to do |
| `BLOCK [403]` | 403 | Curation policy denied | Review with security team; may need policy exception |
| `MISS  [404]` | 404 | Not in upstream | Feed into rescue-local remediation |
| `FAIL  [---]` | 000 | Network/TLS error | Retry, check network path |

## Concurrency (Python only)

`--concurrency N` (default 8) enables parallel HEAD workers. HEAD is I/O-bound so speedup is roughly linear up to ~8-16 workers, then tapers as network and upstream become the bottleneck.

Recommended values:
- Maven Central: `8-16`
- Sonatype OSS: `4-8`
- Private Nexus / Artifactory: `4-8`

Watch for `429` responses or connection resets — drop the concurrency if they appear.

Progress counter `[X/N]` appears on each result line; elapsed time at completion.

## Rescue-local remediation

For coords flagged 404 by [check-upstream-maven](./check-upstream-maven.md):

1. Create a Maven rescue local repo (e.g. `<prefix>-maven-rescue-local`).
2. Copy affected `.jar` + `.pom` files from R1's cache:
   ```bash
   # For coord "com.google.guava:guava:31.1-jre"
   GROUP_PATH=$(echo "com.google.guava" | tr '.' '/')
   jf rt cp \
     <R1>-cache/$GROUP_PATH/guava/31.1-jre/ \
     <rescue-local>/$GROUP_PATH/guava/31.1-jre/ \
     --recursive
   ```
3. Add rescue local to virtual V1 alongside R2, ordered so R2 is checked first with rescue as fallback.

**Trade-off:** Curation only intercepts remotes. Artifacts in a local repo bypass Curation. Compensating controls: Xray still indexes; scope discipline (only confirmed-missing artifacts); treat as frozen and sunset as pins upgrade.

## Troubleshooting

**All checks return 403** — either Curation is blocking everything (unlikely unless an aggressive policy is in place), or R2's upstream credentials are wrong. Check R2's config:
```bash
jf rt curl "/api/repositories/<targetRepo>" --server-id <id> \
  | jq '{key, rclass, url, packageType, username}'
```

**Sparse 403s** — real Curation policy blocks on those specific versions. Coordinate with security to allowlist or bump pins.

**BOMs showing as `MISS [404]` with `jar=404 pom=200`** — old script version that didn't respect `:pom` suffix. Current version skips the `.jar` HEAD for POM-only coords entirely.

**60-second stalls** — network path from your machine to R2 is slow, or R2's upstream fetch is slow. Not the script's fault. Try `-v` to see per-phase timing.

**Version parsing looks wrong in list output** — the regex assumes `<artifactId>-<version>.<ext>` where the version starts with a digit. Timestamped snapshots or unusual versioning schemes can confuse it. Inspect with:
```bash
jf rt curl "/api/storage/<sourceRepo>-cache/?list&deep=1" --server-id <id> | jq '.files[]?.uri' | head
```

## Related

- [`check-upstream-maven.md`](./check-upstream-maven.md) — companion script for upstream availability checks
- [`README.md`](./README.md) — Maven folder overview and quick-start
- [`python/README.md`](./python/README.md) — Python-specific setup and concurrency notes
- [`../README.md`](../README.md) — top-level index of all package types
