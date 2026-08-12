# check-upstream-maven.sh

Companion to [prepopulate-r2-maven.sh](./prepopulate-r2-maven.md). Given a list of Maven coordinates, HEAD each expected file (`.jar` and/or `.pom`) directly against the upstream URL configured on the source remote. Emits a report of statuses plus a text file listing only the missing ones, ready to feed into the rescue-local remediation step.

For the analogs: [check-upstream.md](./check-upstream.md) (npm), [check-upstream-pypi.md](./check-upstream-pypi.md) (pypi), [check-upstream-docker.md](./check-upstream-docker.md) (docker).

## What it does

Reads the upstream URL from R1's config, then for each coord in the input list sends:

```
HEAD <upstream>/<groupPath>/<artifactId>/<version>/<artifactId>-<version>.pom
HEAD <upstream>/<groupPath>/<artifactId>/<version>/<artifactId>-<version>.jar   (unless POM-only)
```

Uses `-sSLI` (silent, follow redirects, HEAD) — Maven Central and Sonatype OSS both redirect to CDNs, so `-L` is needed to reach the real 200/404. `-I` (rather than `-X HEAD`) prevents the partial-body stall we hit historically on direct `-X HEAD`.

Per-coord status is the rollup of per-file results (worst wins: FAIL > 403 > 404 > 200).

## Coordinate format

Matches [prepopulate-r2-maven.sh](./prepopulate-r2-maven.md) list output:

```
groupId:artifactId:version              → regular artifact, checks .jar + .pom
groupId:artifactId:version:pom          → POM-only (BOM, parent pom), checks only .pom
```

Examples:

```
com.google.guava:guava:31.1-jre
org.apache.commons:commons-lang3:3.12.0
org.apache.cassandra:java-driver-bom:4.19.2:pom
com.fasterxml.jackson:jackson-bom:2.17.2:pom
```

The `:pom` suffix tells the script to skip the `.jar` HEAD, so BOMs don't show misleading `jar=404` results.

## Prerequisites

- `jf` CLI configured with a server ID (only used to read R1's config).
- `jq`.
- `curl`.

Verify:

```bash
jf c show <your-server-id>
which jq curl
```

## Quick start

```bash
# Using the coord list from prepopulate
./check-upstream-maven.sh \
  --serverid psblr --sourceRepo maven-remote \
  --fromFile maven-artifacts-*.txt

# Or auto-enumerate R1's coords via AQL
./check-upstream-maven.sh \
  --serverid psblr --sourceRepo maven-remote \
  --downloadedWithin 1y

# With per-file timing to diagnose slow upstreams
./check-upstream-maven.sh \
  --serverid psblr --sourceRepo maven-remote \
  --fromFile maven-artifacts-*.txt -v
```

## Flag reference

| Flag | Required | Description |
|---|---|---|
| `--serverid <id>` | yes | JFrog CLI server ID (only used to read R1's config) |
| `--sourceRepo <repo>` | yes | Maven remote whose upstream URL we resolve |
| `--fromFile <path>` | one of | Read coord list from a file |
| `--downloadedWithin <dur>` | one of | AQL filter when auto-enumerating |
| `--createdWithin <dur>` | no | Additional AQL filter on `created` |
| `--connect-timeout <sec>` | no | TCP+TLS connect timeout. Default 10s |
| `--verbose`, `-v` | no | Print per-file curl phase timing (dns/tls/ttfb/total) |

**Duration format**: `1d`, `1w`, `6mo`, `1y`.

**Input file format**: one coord per line. Lines starting with `#` and blank lines are ignored. Trailing `\r` from Windows-edited files is stripped automatically.

## Output files

- **`upstream-check-maven-<repo>-<timestamp>.csv`** — full per-file report. Columns: `coord,artifact_type,upstream_status`. One row per file (so a regular coord with jar+pom gets two rows, a BOM gets one).
- **`upstream-missing-maven-<repo>-<timestamp>.txt`** — one coord per line, only entries where any expected file came back 404. Deleted automatically if empty.

Summary printed at the end:

```
Summary (by artifact_type + status):
  jar/200      : 823
  jar/404      : 3
  pom/200      : 845
  pom/404      : 3
3 coordinate(s) with at least one 404 file: upstream-missing-maven-<ts>.txt
```

The per-file breakdown helps triage: a MISS on the jar but OK on the pom might mean the artifact was renamed upstream but the pom is still there; a MISS on both is a hard 404 (fully missing artifact).

## Interpreting results

Per-coord rollup:

| Console label | Meaning | Action |
|---|---|---|
| `OK    [200]` | All expected files are on upstream | Nothing to do |
| `AUTH  [401/403]` | Auth failed at some layer | Upstream requires creds R1 doesn't have; check R1's upstream credentials |
| `MISS  [404]` | At least one file (jar or pom) is not in upstream | Feed into rescue-local remediation |
| `FAIL  [---]` | Network / timeout / connection error | Retry, check network path to upstream |

Look at the CSV for per-file detail — the console shows the rollup only, but per-file info is what you need to explain a specific failure ("jar exists but pom is 404" is a different story from "both are 404").


## Troubleshooting

**All checks return 401 or 403** — upstream requires auth. Maven Central is anonymous-read; if you're checking against a private Nexus or Artifactory mirror, R1's upstream credentials are wrong or expired. Check the repo config:
```bash
jf rt curl "/api/repositories/<sourceRepo>" --server-id <id> \
  | jq '{key, rclass, url, username}'
```

**A check returns 200 but the same coord failed prepopulate** — the file exists upstream but there's a subtle issue (unusual media type, signature check failing, etc.). Rare; see [prepopulate-r2-maven.md](./prepopulate-r2-maven.md) troubleshooting for the specific errors.

**Redirects to unexpected hosts** — Maven Central redirects to CDN (`https://repo1.maven.org` → `https://repo.maven.apache.org`). That's normal, `-L` follows it. If you see redirects to something totally unrelated (a corporate proxy landing page, a Zscaler blocker, etc.), your network is intercepting outbound HTTPS. Would need to route via R1 like the docker/pypi check-upstream scripts do — that pattern hasn't been added here yet since maven traffic isn't commonly proxied. Ask if you need it.

**Everything returns FAIL** — network path to upstream is broken. Test manually:
```bash
curl -sSLI -o /dev/null -w "http=%{http_code}\n" \
  https://repo.maven.apache.org/maven2/com/google/guava/guava/31.1-jre/guava-31.1-jre.jar
```
If that returns 200, the script's URL construction is right and something in the loop is failing. If it errors, the network path is the issue.

**BOMs showing as `MISS [404]` with `jar=404 pom=200`** — old script version that didn't respect the `:pom` suffix. Update. Current version skips the jar HEAD for POM-only coords entirely.
