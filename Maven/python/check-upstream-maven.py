#!/usr/bin/env python3
"""
check-upstream-maven.py
------------------------------------------------------------------
Python port of check-upstream-maven.sh.

Given a list of Maven coordinates (from a file or from AQL against an
R1 remote), test each expected file (.jar and/or .pom) against the
upstream URL configured on the source remote.

Emits:
  - Full CSV report: coord, artifact_type, upstream_status
  - Missing-only text file: coords where any expected file 404'd

Coordinate format (matches prepopulate-r2-maven output):
  groupId:artifactId:version           -> regular artifact
  groupId:artifactId:version:pom       -> POM-only (BOM, parent pom)
"""

import argparse
import re
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import List, Optional, Tuple

import requests

from prepop_lib import (
    HeadResult, JFConfig, ReportWriter,
    die, get_jf_config, head_with_timing, log, log_verbose,
    parse_duration_to_cutoff, print_status_summary, read_input_list,
    run_aql_spec_search, run_jf, timestamp_slug, verify_serverid,
)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Check whether Maven coordinates still exist upstream.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--serverid", required=True, help="JFrog CLI server ID")
    p.add_argument("--sourceRepo", required=True, help="Maven remote whose upstream we resolve")
    p.add_argument("--fromFile", help="Read coord list from a file")
    p.add_argument("--downloadedWithin", help="AQL filter on stat.downloaded (e.g. 1y)")
    p.add_argument("--createdWithin", help="AQL filter on created (e.g. 1y)")
    p.add_argument("--connect-timeout", type=float, default=10.0,
                   dest="connect_timeout", help="TCP+TLS connect timeout (default 10s)")
    p.add_argument("--via-r1", action="store_true", dest="via_r1",
                   help="Route HEAD through R1's own repo endpoint on the tenant "
                        "instead of hitting upstream directly. Use when corporate "
                        "proxies (Zscaler etc.) block direct Maven Central from the client.")
    p.add_argument("--rescueLocal", dest="rescueLocal", default="",
                   help="Local repo to copy missing artifacts into (from R1 cache). "
                        "When set, each MISS triggers a jf rt cp --recursive from "
                        "<sourceRepo>-cache/<groupPath>/<artifactId>/<version>/ to "
                        "<rescueLocal>/<same-path>/. Rescue local must exist and be "
                        "a local repo of Maven package type.")
    p.add_argument("--concurrency", type=int, default=8,
                   help="Number of concurrent HEAD requests (default 8). Increase for "
                        "faster scans; watch for upstream rate limits.")
    p.add_argument("--verbose", "-v", action="store_true",
                   help="Print per-file curl phase timing")
    return p.parse_args()


def get_upstream_url(sourceRepo: str, serverid: str) -> str:
    """Read R1's upstream URL from its config."""
    rc, out, _ = run_jf(
        ["rt", "curl", "-X", "GET", f"/api/repositories/{sourceRepo}",
         f"--server-id={serverid}"],
        check=True,
    )
    import json
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        die(f"could not parse repo config for '{sourceRepo}'")
    url = (data.get("url") or "").rstrip("/")
    if not url:
        die(f"could not read upstream URL for {sourceRepo}\n"
            "       (is it a remote repo? does the token have read access?)")
    return url


def build_spec(sourceRepo: str, downloadedWithin: str = None,
               createdWithin: str = None) -> dict:
    """Build the AQL spec dict for finding .jar and .pom files in R1's cache."""
    conditions = {
        "$and": [
            {"repo": f"{sourceRepo}-cache"},
            {"type": "file"},
            {"$or": [
                {"name": {"$match": "*.jar"}},
                {"name": {"$match": "*.pom"}},
            ]},
            {"name": {"$nmatch": "*-sources.jar"}},
            {"name": {"$nmatch": "*-javadoc.jar"}},
        ]
    }
    if downloadedWithin:
        conditions["$and"].append(
            {"stat.downloaded": {"$gt": parse_duration_to_cutoff(downloadedWithin)}}
        )
        log(f"Filter: stat.downloaded > within {downloadedWithin}")
    if createdWithin:
        conditions["$and"].append(
            {"created": {"$gt": parse_duration_to_cutoff(createdWithin)}}
        )
        log(f"Filter: created > within {createdWithin}")
    return {"files": [{"aql": {"items.find": conditions}}]}


_PATH_RE = re.compile(r"^(?P<pp>.+)/[^/]+\.(?P<ext>jar|pom)$")


def aql_results_to_coords(results: list, source_repo: str) -> List[str]:
    """
    Group AQL results by g:a:v. If any file for a coord has ext=jar, emit
    'g:a:v'. Otherwise (POM-only) emit 'g:a:v:pom'.
    """
    prefix = f"{source_repo}-cache/"
    # Collect (gav, ext) tuples
    by_gav: dict = {}
    for entry in results:
        path = entry.get("path", "")
        if path.startswith(prefix):
            path = path[len(prefix):]
        m = _PATH_RE.match(path)
        if not m:
            continue
        parts = m.group("pp").split("/")
        if len(parts) < 3:
            continue
        gav = f"{'.'.join(parts[:-2])}:{parts[-2]}:{parts[-1]}"
        by_gav.setdefault(gav, set()).add(m.group("ext"))

    coords = []
    for gav, exts in sorted(by_gav.items()):
        if "jar" in exts:
            coords.append(gav)
        else:
            coords.append(f"{gav}:pom")
    return coords


def coord_to_files(coord: str) -> List[Tuple[str, str]]:
    """
    Convert coord to list of (type, path) tuples for each file to HEAD.
    Regular (3 parts): pom + jar
    POM-only (4 parts, :pom suffix): pom only
    """
    parts = coord.split(":")
    if len(parts) not in (3, 4):
        return []
    group_id, artifact_id, version = parts[0], parts[1], parts[2]
    packaging = parts[3] if len(parts) == 4 else ""

    group_path = group_id.replace(".", "/")
    base = f"{group_path}/{artifact_id}/{version}/{artifact_id}-{version}"

    files = [("pom", f"{base}.pom")]
    if packaging != "pom":
        files.append(("jar", f"{base}.jar"))
    return files


def coord_to_version_dir(coord: str) -> Optional[str]:
    """
    Convert coord to its version-directory path in Artifactory.
    e.g. 'com.google.guava:guava:31.1-jre' -> 'com/google/guava/guava/31.1-jre'
    """
    parts = coord.split(":")
    if len(parts) not in (3, 4):
        return None
    group_id, artifact_id, version = parts[0], parts[1], parts[2]
    group_path = group_id.replace(".", "/")
    return f"{group_path}/{artifact_id}/{version}"


def rescue_from_r1_maven(coord: str, source_repo: str, rescue_local: str,
                         serverid: str) -> Tuple[int, int, str]:
    """
    Copy the version directory for coord from R1's cache to the rescue local
    (jar + pom + any siblings like -sources.jar, -javadoc.jar, checksums).

    Returns (matched, copied, error_message). error_message is empty on success.
      matched = 1 if the version dir was found in R1 cache, else 0
      copied  = 1 if the copy succeeded, else 0
    (Maven is dir-scoped so we count directories, not individual files.
    Files-in-dir count would need a second AQL — not worth the extra round-trip.)
    """
    version_dir = coord_to_version_dir(coord)
    if not version_dir:
        return (0, 0, f"unparseable coord '{coord}'")

    src_repo_cache = f"{source_repo}-cache"

    # Verify the version dir exists in R1's cache (via storage API)
    rc, out, _ = run_jf(
        ["rt", "curl", "-X", "GET",
         f"/api/storage/{src_repo_cache}/{version_dir}/",
         f"--server-id={serverid}"],
        check=False,
    )
    if rc != 0 or '"errors"' in out:
        return (0, 0, f"not in {src_repo_cache}/{version_dir}/")

    # Do the recursive copy
    src = f"{src_repo_cache}/{version_dir}/"
    dst = f"{rescue_local}/{version_dir}/"
    result = subprocess.run(
        ["jf", "rt", "cp", src, dst, f"--server-id={serverid}", "--recursive=true"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
    )
    if result.returncode == 0:
        return (1, 1, "")
    err = (result.stderr or result.stdout).strip().splitlines()
    return (1, 0, err[-1][:80] if err else "unknown jf rt cp error")


def check_one(coord: str, upstream_base: str, timeout: float, verbose: bool,
              session: requests.Session, writer: ReportWriter,
              io_lock: threading.Lock, progress: dict, total: int,
              via_r1: bool = False, jf_cfg: "JFConfig" = None,
              sourceRepo: str = "",
              rescue_local: str = "", serverid: str = "",
              rescue_stats: Optional[dict] = None) -> str:
    """
    HEAD each expected file for the coord. Return the rolled-up overall status.
    Thread-safe: all log() and writer.row() calls are guarded by io_lock so
    output stays coherent under concurrent execution.

    When via_r1=True, HEADs go through <tenant>/<sourceRepo>/<path> using
    tenant auth from jf_cfg. Useful when a corporate proxy blocks direct
    Maven Central from the client's network.
    """
    is_pom_only = coord.endswith(":pom")
    display = f"{coord} (POM-only)" if is_pom_only else coord

    files = coord_to_files(coord)
    if not files:
        with io_lock:
            log(f"  ?     [---]  {coord}  (unparseable coord)")
        return "PARSE"

    # Choose base URL and auth per mode
    if via_r1:
        base = f"{jf_cfg.url}/{sourceRepo}"
        headers = jf_cfg.auth_headers
        auth = jf_cfg.basic_auth
    else:
        base = upstream_base
        headers = None
        auth = None

    # Do all the network I/O outside the lock — that's the whole point of concurrency.
    overall = "200"
    status_bits = []
    per_file_results: List[Tuple[str, str, str]] = []  # (type, status, timing_detail)
    for artifact_type, rel_path in files:
        url = f"{base}/{rel_path}"
        result = head_with_timing(url, headers=headers, auth=auth,
                                  timeout=timeout, verbose=verbose, session=session)
        status = result.status
        status_bits.append(f"{artifact_type}={status}")
        # Roll up worst status
        if status == "000":
            overall = "FAIL"
        elif status in ("401", "403") and overall not in ("FAIL",):
            overall = "AUTH"
        elif status == "404" and overall in ("200", "AUTH"):
            overall = "404"
        per_file_results.append((artifact_type, status, result.timing_detail))

    status_line = " ".join(status_bits)
    auth_hint = "check server-id auth" if via_r1 else "upstream requires auth; try --via-r1"
    label_map = {
        "200":  f"OK    [200]  {display}  ({status_line})",
        "AUTH": f"AUTH  [401/403]  {display}  ({status_line})  ({auth_hint})",
        "404":  f"MISS  [404]  {display}  ({status_line})  (missing from upstream)",
        "FAIL": f"FAIL  [---]  {display}  ({status_line})",
    }
    label = label_map.get(overall, f'?     [{overall}]  {display}  ({status_line})')

    # Rescue-copy from R1 cache if MISS and rescue_local set.
    # Subprocess I/O happens outside io_lock so multiple rescues can happen in parallel.
    rescue_line = ""
    if overall == "404" and rescue_local:
        matched, copied, err = rescue_from_r1_maven(
            coord, sourceRepo, rescue_local, serverid
        )
        if matched == 0:
            rescue_line = f"RESCUE: nothing found in {sourceRepo}-cache ({err})"
            if rescue_stats is not None:
                with io_lock:
                    rescue_stats["nomatch"] += 1
        elif copied == matched:
            rescue_line = f"RESCUE: copied version dir to {rescue_local}"
            if rescue_stats is not None:
                with io_lock:
                    rescue_stats["rescued"] += 1
        else:
            rescue_line = f"RESCUE: FAILED (last err: {err})"
            if rescue_stats is not None:
                with io_lock:
                    rescue_stats["failed"] += 1

    # Now serialize the I/O — log line, CSV writes, progress counter — under the lock.
    with io_lock:
        progress["done"] += 1
        counter = f"[{progress['done']}/{total}]"
        log(f"  {counter}  {label}")
        if rescue_line:
            log(f"         → {rescue_line}")
        for artifact_type, status, timing in per_file_results:
            writer.row({
                "coord": coord,
                "artifact_type": artifact_type,
                "upstream_status": status,
            })
            if verbose and timing:
                log(f"         {artifact_type} timing: {timing}")
    return overall


def main() -> None:
    args = parse_args()

    log("=== Upstream check (maven) ===")
    log(f"Source repo: {args.sourceRepo}")

    verify_serverid(args.serverid)

    # Preflight the rescue local if requested
    if args.rescueLocal:
        rc, out, _ = run_jf(
            ["rt", "curl", "-X", "GET", f"/api/repositories/{args.rescueLocal}",
             f"--server-id={args.serverid}"],
            check=False,
        )
        if rc != 0 or not out.strip():
            die(f"rescue local '{args.rescueLocal}' does not exist. Create it first "
                f"(as a local repo of Maven package type) then re-run.")
        import json as _json
        try:
            repo_data = _json.loads(out)
        except _json.JSONDecodeError:
            die(f"could not parse repo config for '{args.rescueLocal}'")
        rclass = repo_data.get("rclass", "").lower()
        if rclass != "local":
            die(f"'{args.rescueLocal}' is a '{rclass}' repo, must be 'local' for rescue")
        pkg_type = repo_data.get("packageType", "").lower()
        if pkg_type not in ("maven", ""):
            log(f"WARN: rescue local packageType is '{pkg_type}', expected 'maven'. "
                f"Copies may work but resolution might not.")
        log(f"Rescue local: {args.rescueLocal} (local/{pkg_type or 'unknown'})")

    if args.via_r1:
        jf_cfg = get_jf_config(args.serverid)
        upstream_base = ""
        log(f"Mode: via R1 ({jf_cfg.url}/{args.sourceRepo}/...)")
    else:
        jf_cfg = None
        upstream_base = get_upstream_url(args.sourceRepo, args.serverid)
        log(f"Upstream base: {upstream_base}")

    # Build the coord list either from --fromFile or from AQL against R1
    if args.fromFile:
        log(f"Input: file {args.fromFile}")
        coords = read_input_list(args.fromFile)
    else:
        log(f"Input: AQL against {args.sourceRepo}")
        spec = build_spec(args.sourceRepo, args.downloadedWithin, args.createdWithin)
        results = run_aql_spec_search(spec, args.serverid)
        coords = aql_results_to_coords(results, args.sourceRepo)
        # Write intermediate file too, for parity with bash
        intermediate = f"check-maven-list-{timestamp_slug()}.txt"
        with open(intermediate, "w") as f:
            for c in coords:
                f.write(c + "\n")
        log(f"Found {len(coords)} Maven coordinates. List: {intermediate}")

    log(f"Checking coordinates with concurrency={args.concurrency}...")
    t_start = time.perf_counter()

    report_csv = f"upstream-check-maven-{args.sourceRepo}-{timestamp_slug()}.csv"
    missing_txt = f"upstream-missing-maven-{args.sourceRepo}-{timestamp_slug()}.txt"

    session = requests.Session()
    adapter = requests.adapters.HTTPAdapter(
        pool_connections=args.concurrency,
        pool_maxsize=args.concurrency,
        max_retries=0,
    )
    session.mount("http://", adapter)
    session.mount("https://", adapter)

    missing_coords: List[str] = []
    missing_lock = threading.Lock()
    io_lock = threading.Lock()
    progress = {"done": 0}
    total = len(coords)
    rescue_stats = {"rescued": 0, "failed": 0, "nomatch": 0}

    with ReportWriter(report_csv, ["coord", "artifact_type", "upstream_status"]) as writer:
        with ThreadPoolExecutor(max_workers=args.concurrency) as executor:
            futures = {
                executor.submit(
                    check_one, coord, upstream_base,
                    args.connect_timeout, args.verbose,
                    session, writer, io_lock, progress, total,
                    args.via_r1, jf_cfg, args.sourceRepo,
                    args.rescueLocal, args.serverid, rescue_stats,
                ): coord
                for coord in coords
            }
            for future in as_completed(futures):
                coord = futures[future]
                try:
                    overall = future.result()
                    if overall == "404":
                        with missing_lock:
                            missing_coords.append(coord)
                except Exception as e:
                    with io_lock:
                        log(f"  FAIL  [---]  {coord}  (worker exception: {e})")

    elapsed = time.perf_counter() - t_start
    log(f"Complete. {len(coords)} coordinates checked in {elapsed:.1f}s. Report: {report_csv}")

    # Per-file breakdown summary
    log("Summary (by artifact_type + status):")
    import csv as _csv
    from collections import Counter
    counts: Counter = Counter()
    with open(report_csv) as f:
        for row in _csv.DictReader(f):
            counts[f"{row['artifact_type']}/{row['upstream_status']}"] += 1
    for key in sorted(counts):
        log(f"  {key:<15} : {counts[key]}")

    # Emit missing.txt
    if missing_coords:
        with open(missing_txt, "w") as f:
            for c in sorted(set(missing_coords)):
                f.write(c + "\n")
        log(f"{len(set(missing_coords))} coordinate(s) with at least one 404 file: {missing_txt}")
        if args.rescueLocal:
            log("Rescue summary:")
            log(f"  fully rescued  : {rescue_stats['rescued']} coord(s)")
            log(f"  failed to copy : {rescue_stats['failed']} coord(s)")
            log(f"  no cache match : {rescue_stats['nomatch']} coord(s) (nothing in R1 cache to copy)")
            log("Verify:")
            log(f"  jf rt search '{args.rescueLocal}/*' --server-id {args.serverid} | jq 'length'")
        else:
            log("Feed the missing.txt file into the rescue-local remediation step,")
            log("OR re-run with --rescueLocal <repo> to automate the copy.")
    else:
        log("No missing artifacts detected. Nothing to remediate.")

    log("=== Done ===")


if __name__ == "__main__":
    main()
