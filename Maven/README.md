# prepopulate-r2-maven.sh

Maven analog of [prepopulate-r2.sh](./README.md). Enumerate Maven artifacts in R1's cache, then curl HEAD each artifact's `.jar` and `.pom` through R2 to warm R2's cache and force Curation to evaluate every artifact.


For detecting artifacts that no longer exist upstream, see [check-upstream-maven](./check-upstream-maven.sh).

## What it does

**Two subcommands:**

- **`list`** — Enumerate `.jar` and `.pom` files in R1's cache via AQL. Optional time filters (`--downloadedWithin`, `--createdWithin`) narrow the list to recent activity. Output is one Maven coordinate per line.
- **`prepopulate`** — Read the coord list and for each entry issue HEAD requests against R2 for the expected files. Reports 200 / 403 / 404 / FAIL per coord (rolled up from per-file results).



## Handling POM-only artifacts (BOMs, parent poms)

Some Maven artifacts have only a `.pom` file, no `.jar` — Bill of Materials (BOM) and parent POMs are the common cases. The script detects these at `list` time and marks them so `prepopulate` doesn't waste requests on non-existent JARs.

| R1 has | `list` emits | `prepopulate` fetches |
|---|---|---|
| Both `.jar` and `.pom` | `g:a:v` | `.jar` + `.pom` |
| Only `.pom` (BOM/parent) | `g:a:v:pom` | `.pom` only |

Example output from `list`:

```
org.apache.httpcomponents.client5:httpclient5:5.5.2
org.apache.cassandra:java-driver-bom:4.19.2:pom
com.fasterxml.jackson:jackson-bom:2.17.2:pom
com.google.guava:guava:31.1-jre
```

## Prerequisites

- `jf` CLI configured with a server ID for your Artifactory tenant.
- `jq` for JSON parsing.
- `curl`.

Verify:

```bash
jf c show <your-server-id>
which jq curl
```

## Quick start

```bash
# 1. List R1's active set (last year)
./prepopulate-r2-maven.sh list \
  --serverid psblr --sourceRepo maven-remote \
  --downloadedWithin 1y
# → maven-artifacts-<pid>.txt

# 2. Dry-run against R2 to see the HEAD URLs
./prepopulate-r2-maven.sh prepopulate \
  --serverid psblr --targetRepo maven-remote2 \
  --fromFile maven-artifacts-<pid>.txt \
  --dry-run

# 3. Real run
./prepopulate-r2-maven.sh prepopulate \
  --serverid psblr --targetRepo maven-remote2 \
  --fromFile maven-artifacts-<pid>.txt
```

## Flag reference

### `list` subcommand

| Flag | Required | Description |
|---|---|---|
| `--serverid <id>` | yes | JFrog CLI server ID |
| `--sourceRepo <name>` | yes | R1 remote name (without `-cache` suffix) |
| `--downloadedWithin <dur>` | no | Include only items downloaded within this window |
| `--createdWithin <dur>` | no | Include only items created within this window |
| `--includeSources` | no | Also emit `-sources.jar` entries. Default: skip |
| `--includeJavadoc` | no | Also emit `-javadoc.jar` entries. Default: skip |

### `prepopulate` subcommand

| Flag | Required | Description |
|---|---|---|
| `--serverid <id>` | yes | JFrog CLI server ID |
| `--targetRepo <name>` | yes | R2 remote name to warm |
| `--sourceRepo <name>` | one of | Enumerate R1 via AQL as the source list |
| `--fromFile <path>` | one of | Read coord list from a file |
| `--downloadedWithin <dur>` | no | Time filter when using `--sourceRepo` |
| `--createdWithin <dur>` | no | Time filter when using `--sourceRepo` |
| `--withMetadata` | no | Also HEAD `maven-metadata.xml` at the artifact level |
| `--dry-run` | no | Print HEAD URLs, do not execute |
| `--connect-timeout <sec>` | no | TCP+TLS connect timeout. Default 10s |
| `--verbose`, `-v` | no | Print per-file curl timing (dns/tls/ttfb/total) — useful for diagnosing cold-cache slowness |

**Duration format**: `1d`, `1w`, `6mo`, `1y`.

**Input file format**: one coord per line. Lines starting with `#` and blank lines are ignored. Trailing `\r` from Windows-edited files is stripped automatically.

## Coordinate format

Standard Maven coord syntax with an optional packaging suffix:

```
groupId:artifactId:version              → regular artifact
groupId:artifactId:version:pom          → POM-only (BOM, parent pom)
```

Examples:

```
ch.qos.logback:logback-classic:1.5.32
com.google.guava:guava:31.1-jre
org.apache.cassandra:java-driver-bom:4.19.2:pom
com.fasterxml.jackson:jackson-bom:2.17.2:pom
```

## Output files

- **`maven-artifacts-<pid>.txt`** — output of `list`, or intermediate from `prepopulate --sourceRepo`. One coord per line.
- **`maven-prepop-report-<target>-<timestamp>.csv`** — from `prepopulate`. Columns: `coord,artifact_type,http_status`. One row per file HEAD (so a coord with jar+pom gets two rows).

Summary printed at end of `prepopulate`:

```
jar/200      : 823
jar/404      : 3
pom/200      : 845
pom/403      : 2
pom/404      : 3
```

## Interpreting results

Per-coord status is the rollup of per-file results (worst wins: FAIL > 403 > 404 > 200).

| Status | Label | Meaning | Action |
|---|---|---|---|
| 200 | `OK` | All expected files warmed in R2's cache | Nothing to do |
| 403 | `BLOCK` | Curation policy denied one or more files | Review with security. Distinguish jar vs pom denials via the CSV |
| 404 | `MISS` | At least one file is not in upstream | Feed into rescue-local remediation |
| FAIL | `FAIL` | Network / timeout / connection error | Check network path to R2, retry |

The per-file report row helps triage — a MISS on the jar but OK on the pom might mean the artifact was renamed upstream but the pom is still there; a MISS on both is a hard 404.

## Rescue-local remediation

For coords flagged 404 (see `check-upstream-maven` for a systematic pre-check):

1. Create a rescue local repo for Maven artifacts (e.g. `<prefix>-maven-rescue-local`).
2. Copy the affected `.jar` and `.pom` files from `R1-cache` into the rescue local:
   ```bash
   jf rt cp <R1>-cache/<groupPath>/<artifactId>/<version>/ <rescue-local>/<groupPath>/<artifactId>/<version>/
   ```
3. Add the rescue local to virtual V1 alongside R2, ordered so R2 is checked first with rescue local as fallback.

**Trade-off:** Curation only intercepts remote fetches. Artifacts in a local repo bypass Curation for the lifetime of the copy. Compensating controls: Xray still indexes the local repo; scope discipline (only confirmed-missing artifacts, not bulk R1 copies); treat the rescue local as frozen and sunset it as pins are upgraded.