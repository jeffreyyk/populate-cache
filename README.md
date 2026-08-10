# prepopulate-r2

Pre-populate a new smart remote (**R2**) from an existing remote's cache (**R1**), so that Curation policies evaluate every artifact and R2's cache is warm before cutover.

Built for the R1 → R2 migration pattern where an old uncurated remote is being replaced by a new curated one inside the same virtual repository. The script lists what R1 has been serving, then triggers R2 to fetch each artifact from its upstream — which forces Curation evaluation and warms R2 in one pass.

## What it does

**Two modes:**

- **`list`** — Enumerate artifacts in R1's cache via AQL. Optional time filters (`--downloadedWithin`, `--createdWithin`). Output is a plain text file, one artifact path per line.
- **`prepopulate`** — Read a list (either freshly generated from R1 or from a file) and issue `HEAD` requests against R2 for each artifact. R2 fetches from upstream, Curation evaluates, cache warms. Reports 200 / 403 / 404 / FAIL per artifact.

## Prerequisites

- `jf` CLI configured with a server ID for your Artifactory tenant.
- `jq` for JSON parsing.
- `curl` (standard on Linux/macOS).

Verify:

```bash
jf c show <your-server-id>
which jq curl
```

## Quick start

```bash
# 1. List what's in R1's cache, filtered to last year of activity
./prepopulate-r2.sh list \
  --serverid sum2 \
  --sourceRepo npm-remote \
  --downloadedWithin 1y

# 2. Dry-run against R2 to check the URLs
./prepopulate-r2.sh prepopulate \
  --serverid sum2 \
  --targetRepo npm-remote2 \
  --fromFile artifacts-<pid>.txt \
  --dry-run

# 3. Real run
./prepopulate-r2.sh prepopulate \
  --serverid sum2 \
  --targetRepo npm-remote2 \
  --fromFile artifacts-<pid>.txt
```

## Workflows

### One-shot (list + prepopulate combined)

Fastest path when you trust the filter and don't need a review step.

```bash
./prepopulate-r2.sh prepopulate \
  --serverid sum2 \
  --targetRepo npm-remote2 \
  --sourceRepo npm-remote \
  --downloadedWithin 1y
```

### Reviewed workflow (recommended for production waves)

Generate a list, review/edit it, feed the reviewed file back in.

```bash
./prepopulate-r2.sh list --serverid sum2 --sourceRepo npm-remote --downloadedWithin 1y
# → artifacts-<pid>.txt

$EDITOR artifacts-<pid>.txt          # comment out with # or delete lines you don't want

./prepopulate-r2.sh prepopulate \
  --serverid sum2 --targetRepo npm-remote2 \
  --fromFile artifacts-<pid>.txt --dry-run

./prepopulate-r2.sh prepopulate \
  --serverid sum2 --targetRepo npm-remote2 \
  --fromFile artifacts-<pid>.txt
```

Lines starting with `#` and blank lines are skipped in file input.

### Dress rehearsal through the virtual

Test the full production resolution path (V1 → R2) instead of hitting R2 directly.

```bash
./prepopulate-r2.sh prepopulate \
  --serverid sum2 --targetRepo npm-remote2 \
  --fromFile artifacts.txt \
  --resolveVia virtual --virtualRepo npm-virtual
```

## Flag reference

### Common

| Flag | Required | Description |
|---|---|---|
| `--serverid <id>` | yes | JFrog CLI server ID (from `jf c add`) |

### `list` subcommand

| Flag | Required | Description |
|---|---|---|
| `--sourceRepo <name>` | yes | R1 remote repo name (without `-cache` suffix) |
| `--downloadedWithin <dur>` | no | Only list artifacts downloaded within this window (e.g. `1y`, `6mo`, `30d`) |
| `--createdWithin <dur>` | no | Only list artifacts created within this window |

### `prepopulate` subcommand

| Flag | Required | Description |
|---|---|---|
| `--targetRepo <name>` | yes | R2 remote repo name to warm |
| `--sourceRepo <name>` | one of | Enumerate R1 via AQL as the source list |
| `--fromFile <path>` | one of | Read source list from a file |
| `--downloadedWithin <dur>` | no | Time filter when using `--sourceRepo` |
| `--createdWithin <dur>` | no | Time filter when using `--sourceRepo` |
| `--resolveVia remote\|virtual` | no | Default `remote` (hit R2 directly). `virtual` routes through V1. |
| `--virtualRepo <name>` | if virtual | V1 name when `--resolveVia virtual` |
| `--dry-run` | no | Print URLs, do not send requests |
| `--connect-timeout <sec>` | no | TCP+TLS connection timeout. Default 10s. Once connected, no ceiling on transfer. |

### Duration format

`1d`, `1w`, `6mo`, `1y` — same vocabulary as the cleanup script.

## Output files

Two files land in the current directory per run:

- **`artifacts-<pid>.txt`** — one artifact path per line (repo-relative, no `<repo>-cache/` prefix). Fed directly into `prepopulate`.
- **`prepop-report-<target>-<timestamp>.csv`** — CSV of `artifact_path,http_status`. Produced by `prepopulate` mode.

Report summary is also printed at the end:

```
HTTP 200 : 847
HTTP 403 :   3
HTTP 404 :  12
```

- **200s** — cache warm, all good.
- **403s** — Curation policy denied. Review with security before cutover.
- **404s** — no longer in upstream. Candidates for the rescue-local repo pattern (see [rescue-local remediation](#rescue-local-remediation)).
- **000 / FAIL** — network/timeout error. Rerun affected artifacts.

## Curation & missing-artifact handling

### The 403 case

A `BLOCK` in the report means R2's Curation policy denied the artifact. This is working as intended — that's exactly the surface pre-population is meant to find before real users hit it. Triage these with security and either raise a policy exception, upgrade the pin to a compliant version, or plan a vendored replacement.

### The 404 case — rescue-local remediation

`MISS` means the artifact was in R1's cache but has been removed from the public upstream since. R2 cannot fetch what upstream doesn't have. The workable pattern:

1. Create a rescue local repo per package type (e.g. `<prefix>-npm-rescue-local`).
2. Copy the affected artifacts from `R1-cache` into the rescue local:
   ```bash
   jf rt cp <R1>-cache/<path> <rescue-local>/<path>
   ```
3. Add the rescue local to the virtual V1 alongside R2, ordered so R2 is checked first with rescue local as fallback.

**Trade-off:** Curation only intercepts remote fetches. Artifacts in a local repo bypass Curation for the lifetime of the copy. Compensating controls: Xray still indexes the local repo; scope discipline (only confirmed-missing artifacts, not bulk R1 copies); treat the rescue local as frozen and sunset it as pins are upgraded.

## Troubleshooting

**`ERROR: server ID '<id>' not configured`** — Run `jf c add` first, or check the ID with `jf c show`.

**`Found 0 artifacts` with a tight time filter** — The tenant may not have organic download activity that recent. Widen the window (`--downloadedWithin 1y`) or switch to `--createdWithin`.

**All statuses come back as `FAIL`** — R2 is likely unreachable. Test directly:
```bash
curl -v -H "Authorization: Bearer <token>" \
  "https://<tenant>/artifactory/<R2>/<some-path>"
```

**Statuses concatenated (e.g. `200000`)** — You're running an old version. Pull latest.

**Filter returns everything unfiltered** — The `.npm/*` metadata is now excluded automatically, but if you see registry docs (`.npm/*/package.json`) in the output, you're on a pre-fix version.

**Docker repos** — This script targets file-based package types (npm, Maven, PyPI, NuGet, Generic). Docker needs manifest-level enumeration and `docker pull`-style fetching; see the reference cleanup script for the manifest pattern.

## Related

- **Cleanup script** (`CleanupScriptWithConditions.sh`) — inverse operation: delete artifacts by AQL criteria. Same auth/spec-file patterns.

## License

Internal PS tool. No external distribution.
