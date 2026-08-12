# prepopulate-r2-maven.sh

Maven analog of [prepopulate-r2.sh](./README.md). Enumerate Maven artifacts in R1's cache, then curl HEAD each artifact's `.jar` and `.pom` through R2 to warm R2's cache and force Curation to evaluate every artifact.

Direct HTTP HEAD through R2 works because Maven has no separate "protocol handler" — everything is a static file at a deterministic URL: `groupId/artifactId/version/artifactId-version.(jar|pom)`. So a HEAD request fetches from upstream and caches, exactly like a real Maven client's GET would. No Maven CLI, no `~/.m2/settings.xml`, no `jf mvn` wrapper needed.

For detecting artifacts that no longer exist upstream, see [check-upstream-maven](./check-upstream-maven.sh).

## What it does

**Two subcommands:**

- **`list`** — Enumerate `.jar` and `.pom` files in R1's cache via AQL. Optional time filters (`--downloadedWithin`, `--createdWithin`) narrow the list to recent activity. Output is one Maven coordinate per line.
- **`prepopulate`** — Read the coord list and for each entry issue HEAD requests against R2 for the expected files. Reports 200 / 403 / 404 / FAIL per coord (rolled up from per-file results).

## Why curl HEAD (not `jf mvn`)

Three candidates were considered:

| | curl HEAD | `jf mvn install` | `jf mvn dependency:get` |
|---|---|---|---|
| Warms `.jar` and `.pom` in R2 | ✅ | ✅ | ✅ |
| Warms `maven-metadata.xml` | ✅ (`--withMetadata`) | ✅ | ✅ |
| Pulls transitive deps | ❌ (matches R1) | ✅ (over-populates) | ❌ |
| Handles BOMs (POM-only) | ✅ | ✅ | ✅ |
| Needs Maven installed | ❌ | ✅ | ✅ |
| Needs `pom.xml` / `settings.xml` | ❌ | ✅ | ✅ |
| JVM startup per call | ❌ | ✅ (2–5s each) | ✅ (2–5s each) |

For arch-faithful pre-population (mirror R1 exactly), curl HEAD is the sweet spot: it hits the same URLs a Maven client would, with none of the JVM startup overhead or transitive-dep bloat. Auth is pulled once from `jf c export` and reused for all HEADs.

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

## Troubleshooting

**`ERROR: server ID '<id>' not configured`** — Run `jf c add`, or verify with `jf c show`.

**Statuses all come back as `FAIL`** — R2 is unreachable, or curl hits a proxy issue. Test one URL directly:
```bash
TOKEN=$(jf c export <serverid> | base64 --decode | jq -r '.accessToken')
curl -sSI -o /dev/null -w "http=%{http_code}\n" \
  -H "Authorization: Bearer $TOKEN" \
  "https://<tenant>/artifactory/<R2>/<groupPath>/<artifactId>/<version>/<artifactId>-<version>.jar"
```
If that returns 200, the script's URL construction is right and something in the loop path is wrong. If it fails, the network path or auth is the issue.

**60-second stalls per HEAD** — you're using `-X HEAD` instead of `-I` somewhere. `-X HEAD` just sets the method; curl still tries to read a body if the server sends `Content-Length`, which stalls until the connection times out. The script uses `-I` which handles this correctly. If you're running a manual test, use `curl -sSLI` not `curl -X HEAD`.

**Backslashes in URLs (`ch\/qos\/logback`)** — bash's `${var//./\/}` pattern substitution keeps the backslash literal on macOS's bash 3.2. The script uses `tr` instead to avoid this. If you see this in your script, update to the latest.

**BOMs showing as MISS on the jar** — you're on an old version that didn't distinguish POM-only coords. Update the script; the current version emits BOMs as `g:a:v:pom` and skips the jar HEAD.

**Snapshot versions with timestamps** — `1.0-20230101.120000-1.jar` are timestamp-versioned snapshots. Current AQL will pick them up, but the coordinate extraction treats the timestamp as the version. If your R1 has snapshot repos, verify the output before running prepopulate.

## Diagnosing per-artifact latency

When a run feels slow and you want to know where the seconds go, add `-v`:

```bash
./prepopulate-r2-maven.sh prepopulate \
  --serverid psblr --targetRepo maven-remote2 \
  --fromFile maven-artifacts.txt -v | head -30
```

Each file gets a timing line showing:

```
[..]   OK    [200]  antlr:antlr:2.7.7:pom (POM-only)  (pom=200)
[..]           pom 200: dns=0.005 tls=0.148 ttfb=59.203 total=59.204
```

Interpreting the fields:
- `dns` — hostname resolution (should be sub-second)
- `tls` — TCP + TLS handshake to R2 (should be sub-second)
- `ttfb` — time to first response byte. **This is where cold-cache fetches show up.** If ttfb is 30–60s but the same URL is 0.3s on a warm re-run, R2 is fetching from upstream + running Curation + writing to cache. That's not something to optimize away — it's the pre-population work you're trying to do.
- `total` — end-to-end. Usually equals ttfb for HEAD.

<!-- verbose mode example -->

## Performance notes

Direct curl HEAD is fast — typically 0.3–1s per file on warm-cache paths, 1–3s on cold-fetch paths through R2. For a wave of 1000 coords × 2 files each (jar+pom) that's roughly 10–30 minutes wall time.

If you need parallelism, wrap the loop in `xargs -P N`:

```bash
awk 'NF' maven-artifacts-<pid>.txt | \
  xargs -P 8 -I{} ./prepopulate-r2-maven.sh prepopulate \
    --serverid psblr --targetRepo maven-remote2 \
    --fromFile <(echo "{}")
```

Roughly 8× the throughput with `-P 8`, subject to R2's own concurrency limits. Watch Artifactory's response times if you push this higher — R2 will eventually rate-limit.

## Related

- **[check-upstream-maven.sh](./check-upstream-maven.sh)** — companion script to detect artifacts removed from upstream (input to rescue-local).
- **[README.md](./README.md)** — npm prepopulate (the original).
- **[prepopulate-r2-docker.md](./prepopulate-r2-docker.md)** — Docker analog using `jf docker pull`.
- **[check-upstream.md](./check-upstream.md)** — npm upstream-check script.