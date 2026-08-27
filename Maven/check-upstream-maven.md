# check-upstream-maven

Companion to [prepopulate-r2-maven](./prepopulate-r2-maven.md). Given a list of Maven coordinates, HEAD each expected file (`.jar` and/or `.pom`) directly against the upstream URL configured on R1. Available as both a bash script (`check-upstream-maven.sh`) and a Python port (`python/check-upstream-maven.py`) with concurrency.

Emits a report of statuses plus a text file listing only the missing ones, ready to feed into rescue-local remediation.

## What it does

Reads the upstream URL from R1's config, then for each coord:

```
HEAD <upstream>/<groupPath>/<artifactId>/<version>/<artifactId>-<version>.pom
HEAD <upstream>/<groupPath>/<artifactId>/<version>/<artifactId>-<version>.jar   (unless POM-only)
```

Uses `-sSLI` (silent, follow redirects, HEAD). Maven Central and Sonatype OSS both redirect to CDNs so `-L` is required. `-I` (rather than `-X HEAD`) prevents Content-Length-driven stalls we hit historically.

Per-coord status is the rollup of per-file results: worst wins (FAIL > 403 > 404 > 200).

## Prerequisites

- **`jf` CLI** — configured with a server ID. Verify: `jf c show <serverid>`
- **`jq` and `curl`** — on PATH
- **Python 3.8+ and `requests`** (Python mode only) — `pip install requests`

## Quick start

**Bash:**
```bash
# Using an existing coord list
./check-upstream-maven.sh \
  --serverid psblr --sourceRepo sum-cba-maven-remote \
  --fromFile maven-artifacts-*.txt

# Auto-enumerate from R1
./check-upstream-maven.sh \
  --serverid psblr --sourceRepo sum-cba-maven-remote \
  --downloadedWithin 1y

# Verbose timing (dns/tls/ttfb/total per file)
./check-upstream-maven.sh \
  --serverid psblr --sourceRepo sum-cba-maven-remote \
  --fromFile maven-artifacts-*.txt -v
```

**Python (with concurrency):**
```bash
cd python/

python3 check-upstream-maven.py \
  --serverid psblr --sourceRepo sum-cba-maven-remote \
  --fromFile maven-artifacts-*.txt --concurrency 8

# With --via-r1 for corporate-proxy environments (Zscaler)
python3 check-upstream-maven.py \
  --serverid psblr --sourceRepo sum-cba-maven-remote \
  --fromFile maven-artifacts-*.txt --concurrency 8 --via-r1

# With auto-rescue: missing artifacts get copied to a local repo
python3 check-upstream-maven.py \
  --serverid psblr --sourceRepo sum-cba-maven-remote \
  --fromFile maven-artifacts-*.txt --concurrency 8 \
  --rescueLocal sum-cba-maven-rescue-local
```

## Flags

```
--serverid <id>             JFrog CLI server ID
--sourceRepo <repo>         R1 Maven remote (only used to read upstream URL)
--fromFile <path>           Read coord list from file (mutually exclusive with time filters)
--downloadedWithin <dur>    AQL filter on stat.downloaded (e.g. 1y, 6mo)
--createdWithin <dur>       Additional AQL filter on created
--via-r1                    Route HEAD through R1's own repo endpoint on the tenant
                            instead of hitting upstream directly. Use when corporate
                            proxies (Zscaler etc.) block direct Maven Central.
--rescueLocal <repo>        Python only: on MISS, jf rt cp the version dir from
                            R1's cache to this local repo. Repo must exist and be
                            a local repo of Maven package type.
--connect-timeout <sec>     TCP+TLS connect timeout (default 10s)
--verbose, -v               Per-file phase timing
--concurrency N             Python only: parallel HEAD workers (default 8)
```

Duration format: `1d`, `1w`, `6mo`, `1y`.

Input file format: one coord per line. Lines starting with `#` and blank lines are ignored. Trailing `\r` is stripped automatically.

## Coordinate format

```
groupId:artifactId:version           regular artifact (HEAD .jar + .pom)
groupId:artifactId:version:pom       POM-only (BOMs, parent poms) — HEAD .pom only
```

The `:pom` suffix tells the script to skip the `.jar` HEAD, so BOMs don't show misleading `jar=404` results.

## Output files

- **`upstream-check-maven-<repo>-<timestamp>.csv`** — full per-file report. Columns: `coord,artifact_type,upstream_status`. One row per file.
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

The per-file breakdown helps triage: a MISS on the jar but OK on the pom means the artifact was renamed upstream but the pom is still there; a MISS on both is a hard 404.

## Interpreting results

Per-coord rollup:

| Console label | Meaning | Action |
|---|---|---|
| `OK    [200]` | All expected files on upstream | Nothing to do |
| `AUTH  [401/403]` | Upstream requires auth | Check R1's upstream credentials |
| `MISS  [404]` | At least one expected file missing | Feed into rescue-local remediation |
| `FAIL  [---]` | Network / timeout / connection error | Retry, check network path |

Per-file detail lives in the CSV — the console rollup is the "worst status" across files for that coord.

## Concurrency (Python only)

`--concurrency N` (default 8) enables parallel HEAD workers. Simple index responses are small and cached at CDN edges, so speedup is roughly linear up to `--concurrency 16` for Maven Central.

Recommended values:
- Maven Central: `8-16`
- Sonatype OSS: `4-8`
- Private Nexus / Artifactory: `4-8`

Progress counter `[X/N]` appears on each result line; elapsed time at completion.

## Rescue-local remediation

For coords flagged 404 by check-upstream — two paths, automated or manual.

### Automated (Python only, recommended)

Pass `--rescueLocal <local-repo>` and the script copies missing artifacts automatically as they're detected. For each MISS, the worker runs `jf rt cp --recursive` on the entire `<groupPath>/<artifactId>/<version>/` directory from R1's cache — capturing jar + pom + optional sources/javadoc + checksums in one operation.

**Setup once** — create the rescue local (Local, Maven package type):

```bash
jf rt curl -X PUT "/api/repositories/sum-cba-maven-rescue-local" --server-id psblr \
  -H "Content-Type: application/json" \
  -d '{"key":"sum-cba-maven-rescue-local","rclass":"local","packageType":"maven"}'
```

**Run with rescue:**

```bash
python3 check-upstream-maven.py \
  --serverid psblr --sourceRepo sum-cba-maven-remote \
  --fromFile maven-artifacts-*.txt --concurrency 8 \
  --rescueLocal sum-cba-maven-rescue-local
```

Preflight validates: repo exists, is `rclass: local`, packageType matches (warn only).

Summary at end:
```
Rescue summary:
  fully rescued  : 8 coord(s)
  failed to copy : 0 coord(s)
  no cache match : 2 coord(s) (nothing in R1 cache to copy)
Verify:
  jf rt search 'sum-cba-maven-rescue-local/*' --server-id psblr | jq 'length'
```

- **fully rescued** — files copied; add rescue-local to V1 as fallback
- **failed to copy** — check per-line `RESCUE: FAILED` log entries
- **no cache match** — missing upstream AND missing from R1 cache = truly gone

### Manual (bash, or when you want granular control)

For coords flagged 404 that you want to copy yourself:

1. Create a Maven rescue local repo (as above).
2. Copy affected `.jar` + `.pom` files from R1's cache:
   ```bash
   # For coord "com.google.guava:guava:31.1-jre"
   GROUP_PATH=$(echo "com.google.guava" | tr '.' '/')
   jf rt cp \
     <R1>-cache/$GROUP_PATH/guava/31.1-jre/ \
     <rescue-local>/$GROUP_PATH/guava/31.1-jre/ \
     --recursive
   ```
3. Add rescue local to virtual V1 alongside R2 with R2 checked first, rescue as fallback.

### Trade-offs

Curation only intercepts remotes. Rescue-local artifacts bypass Curation. Compensating: Xray still indexes them; scope discipline (only confirmed-missing coords); treat as frozen and sunset as pins upgrade.

## Diagnosing slow responses

With `-v`, each file gets a timing line:

```
[..]   OK    [200]  ch.qos.logback:logback-classic:1.5.32  (pom=200 jar=200)
[..]         pom timing: dns=0.005 tls=0.148 ttfb=0.301 total=0.302
[..]         jar timing: dns=0.005 tls=0.147 ttfb=0.298 total=0.298
```

- `dns` / `tls` — sub-second in healthy conditions
- `ttfb` — Maven Central usually 200-500ms; Sonatype OSS slower; private Nexus varies
- `total` ≈ `ttfb` for HEAD

Python's verbose format is coarser: `elapsed=X total=Y` since `requests` doesn't expose all curl phase timers.

## Troubleshooting

**All checks return 401 or 403** — upstream requires auth. Maven Central is anonymous-read; this only happens against private mirrors. Check R1's config:
```bash
jf rt curl "/api/repositories/<sourceRepo>" --server-id <id> \
  | jq '{key, rclass, url, username}'
```

**A check returns 200 but the same coord failed prepopulate** — file exists upstream but has a subtle issue. Rare for Maven; if it happens, share the coord and response.

**Redirects to unexpected hosts** — Maven Central redirects to its CDN, which is normal (`-L` follows). If you see redirects to a corporate proxy landing page, your network is intercepting outbound HTTPS. `--via-r1` isn't implemented for Maven since Maven traffic isn't commonly proxied — ask if you need it.

**Everything returns FAIL** — network path broken. Manual test:
```bash
curl -sSLI -o /dev/null -w "http=%{http_code}\n" \
  https://repo.maven.apache.org/maven2/com/google/guava/guava/31.1-jre/guava-31.1-jre.jar
```
Expected: `http=200`. If not, network path is the issue.

**BOMs showing as `MISS [404]` with `jar=404 pom=200`** — old script that didn't respect `:pom` suffix. Current version skips `.jar` HEAD for POM-only coords.

## Related

- [`prepopulate-r2-maven.md`](./prepopulate-r2-maven.md) — companion prepopulate script
- [`README.md`](./README.md) — Maven folder overview and quick-start
- [`python/README.md`](./python/README.md) — Python-specific setup and concurrency notes
- [`../README.md`](../README.md) — top-level index of all package types
