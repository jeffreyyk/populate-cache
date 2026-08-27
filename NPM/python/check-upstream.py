#!/usr/bin/env python3
"""
check-upstream.py  (NPM)
------------------------------------------------------------------
Python port of check-upstream.sh, with ThreadPoolExecutor concurrency.

Given a list of npm artifact paths (from a file or from AQL against
an R1 remote), HEAD each one against the upstream URL configured on
the source remote (usually https://registry.npmjs.org).

Emits:
  - CSV report: artifact_path, upstream_status
  - Missing-only text file: paths that came back 404 (input to the
    rescue-local remediation step)

Artifact path format:
  eslint/-/eslint-8.57.0.tgz
  @babel/code-frame/-/code-frame-7.29.7.tgz
"""

import argparse
import json
import re
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import List, Optional, Tuple

import requests

from prepop_lib import (
    JFConfig, ReportWriter,
    die, get_jf_config, log, parse_duration_to_cutoff, read_input_list,
    run_aql_spec_search, run_jf, timestamp_slug, verify_serverid,
)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Check whether npm tarballs still exist upstream.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--serverid", required=True)
    p.add_argument("--sourceRepo", required=True,
                   help="npm remote whose upstream URL we resolve")
    p.add_argument("--fromFile", help="Read artifact paths from a file")
    p.add_argument("--downloadedWithin", help="AQL filter (e.g. 1y)")
    p.add_argument("--createdWithin", help="AQL filter (e.g. 1y)")
    p.add_argument("--connect-timeout", type=float, default=10.0,
                   dest="connect_timeout")
    p.add_argument("--via-r1", action="store_true", dest="via_r1",
                   help="Route HEAD through tenant's npm API instead of upstream. "
                        "Use when corporate proxies (Zscaler etc.) block direct "
                        "registry.npmjs.org from the client.")
    p.add_argument("--rescueLocal", dest="rescueLocal", default="",
                   help="Local repo to copy missing artifacts into (from R1 cache). "
                        "When set, each MISS triggers a jf rt cp from "
                        "<sourceRepo>-cache/<pkg>/-/<pkg>-<version>.tgz to "
                        "<rescueLocal>/<same-path>. Rescue local must exist and be "
                        "a local repo of npm package type.")
    p.add_argument("--concurrency", type=int, default=8,
                   help="Number of concurrent HEAD requests (default 8)")
    p.add_argument("--verbose", "-v", action="store_true")
    return p.parse_args()


def get_upstream_url(sourceRepo: str, serverid: str) -> str:
    rc, out, _ = run_jf(
        ["rt", "curl", "-X", "GET", f"/api/repositories/{sourceRepo}",
         f"--server-id={serverid}"],
        check=True,
    )
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        die(f"could not parse repo config for '{sourceRepo}'")
    url = (data.get("url") or "").rstrip("/")
    if not url:
        die(f"could not read upstream URL for {sourceRepo}")
    return url


def build_spec(sourceRepo: str, downloadedWithin: str = None,
               createdWithin: str = None) -> dict:
    conditions = {
        "$and": [
            {"repo": f"{sourceRepo}-cache"},
            {"type": "file"},
            {"name": {"$match": "*.tgz"}},
            {"path": {"$nmatch": ".npm/*"}},
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


def aql_to_artifact_paths(results: list, source_repo: str) -> List[str]:
    """Strip the <repo>-cache/ prefix; artifact paths look like eslint/-/eslint-8.57.0.tgz."""
    prefix = f"{source_repo}-cache/"
    seen = set()
    for entry in results:
        path = entry.get("path", "")
        if path.startswith(prefix):
            path = path[len(prefix):]
        if path.endswith(".tgz"):
            seen.add(path)
    return sorted(seen)


def coord_to_artifact_path(line: str) -> str:
    """
    Convert an input line to the tarball URL path.

    Accepts either form:
      pkg@version                              → <pkg>/-/<basename>-<version>.tgz
      @scope/pkg@version                       → @scope/pkg/-/pkg-<version>.tgz
      <pkg>/-/<pkg>-<version>.tgz              → passthrough

    Lets the same list file (npm-artifacts-*.txt from prepop) work with
    both scripts without a separate conversion step.
    """
    line = line.strip()
    # Passthrough: already an artifact path
    if "/-/" in line and line.endswith(".tgz"):
        return line
    # Not a pkg@version either? Return as-is (URL will 404 with a clear label)
    if "@" not in line:
        return line
    # Find version separator (last @ — the leading one is scope prefix)
    idx = line.rfind("@")
    if idx == 0:
        return line
    pkg = line[:idx]
    version = line[idx + 1:]
    # Scoped: @scope/pkg — basename is the part after /
    if pkg.startswith("@") and "/" in pkg:
        basename = pkg.split("/", 1)[1]
    else:
        basename = pkg
    return f"{pkg}/-/{basename}-{version}.tgz"


def rescue_from_r1_npm(artifact_path: str, source_repo: str,
                       rescue_local: str, serverid: str) -> Tuple[int, int, str]:
    """
    Copy a single tarball from R1's cache to rescue local.
    npm coord = one file, so no AQL needed — verify the path exists then jf rt cp.

    Returns (matched, copied, error_message).
      matched = 1 if file found in R1 cache, else 0
      copied  = 1 if copy succeeded, else 0
    """
    src_repo_cache = f"{source_repo}-cache"

    # Verify the file exists in R1's cache via storage API
    rc, out, _ = run_jf(
        ["rt", "curl", "-X", "GET",
         f"/api/storage/{src_repo_cache}/{artifact_path}",
         f"--server-id={serverid}"],
        check=False,
    )
    if rc != 0 or '"errors"' in out:
        return (0, 0, f"not in {src_repo_cache}/{artifact_path}")

    src = f"{src_repo_cache}/{artifact_path}"
    dst = f"{rescue_local}/{artifact_path}"
    result = subprocess.run(
        ["jf", "rt", "cp", src, dst, f"--server-id={serverid}", "--flat=true"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
    )
    if result.returncode == 0:
        return (1, 1, "")
    err = (result.stderr or result.stdout).strip().splitlines()
    return (1, 0, err[-1][:80] if err else "unknown jf rt cp error")


def check_one(display: str, artifact_path: str, upstream_base: str,
              via_r1: bool, jf_cfg: JFConfig, sourceRepo: str,
              timeout: float, verbose: bool, session: requests.Session,
              writer: ReportWriter,
              io_lock: threading.Lock, progress: dict, total: int,
              rescue_local: str = "", serverid: str = "",
              rescue_stats: Optional[dict] = None) -> str:
    """
    HEAD the artifact against upstream OR against R1's tenant API.
    Thread-safe: network I/O outside io_lock, log() + writer.row() locked.

    `display` is what appears in log lines (usually the original input coord);
    `artifact_path` is the actual tarball path used in the URL.
    """
    if via_r1:
        url = f"{jf_cfg.url}/api/npm/{sourceRepo}/{artifact_path}"
        headers = jf_cfg.auth_headers
        auth = jf_cfg.basic_auth
    else:
        url = f"{upstream_base}/{artifact_path}"
        headers = {}
        auth = None

    status = "000"
    error = ""
    elapsed = 0.0
    t0 = time.perf_counter()
    try:
        resp = session.head(url, headers=headers, auth=auth,
                            timeout=timeout, allow_redirects=True)
        status = str(resp.status_code)
        elapsed = resp.elapsed.total_seconds()
    except requests.exceptions.RequestException as e:
        error = str(e)[:80]
    total_time = time.perf_counter() - t0

    if status == "200":
        label = f"OK    [200]  {display}"
    elif status == "404":
        label = f"MISS  [404]  {display}  (missing from upstream)"
    elif status in ("401", "403"):
        hint = "check server-id auth" if via_r1 else "likely proxy — try --via-r1"
        label = f"AUTH  [{status}]  {display}  ({hint})"
    elif status in ("301", "302", "307"):
        label = f"BLOCK [{status}]  {display}  (proxy/filter redirect)"
    elif status == "000":
        label = f"FAIL  [---]  {display}  ({error or 'unknown error'})"
    else:
        label = f"      [{status}]  {display}"

    # Rescue-copy from R1 cache if MISS and rescue_local set.
    # Subprocess I/O outside io_lock so multiple rescues can run in parallel.
    rescue_line = ""
    if status == "404" and rescue_local:
        matched, copied, err = rescue_from_r1_npm(
            artifact_path, sourceRepo, rescue_local, serverid
        )
        if matched == 0:
            rescue_line = f"RESCUE: nothing found in {sourceRepo}-cache ({err})"
            if rescue_stats is not None:
                with io_lock:
                    rescue_stats["nomatch"] += 1
        elif copied == matched:
            rescue_line = f"RESCUE: copied tarball to {rescue_local}"
            if rescue_stats is not None:
                with io_lock:
                    rescue_stats["rescued"] += 1
        else:
            rescue_line = f"RESCUE: FAILED (last err: {err})"
            if rescue_stats is not None:
                with io_lock:
                    rescue_stats["failed"] += 1

    with io_lock:
        progress["done"] += 1
        counter = f"[{progress['done']}/{total}]"
        log(f"  {counter}  {label}")
        if rescue_line:
            log(f"         → {rescue_line}")
        if verbose:
            log(f"         URL: {url}")
            log(f"         timing: elapsed={elapsed:.3f} total={total_time:.3f}")
        writer.row({"artifact_path": artifact_path, "upstream_status": status})
    return status


def main() -> None:
    args = parse_args()
    log("=== Upstream check (npm) ===")
    log(f"Source repo: {args.sourceRepo}")

    verify_serverid(args.serverid)
    jf_cfg = get_jf_config(args.serverid)

    # Preflight the rescue local if requested
    if args.rescueLocal:
        rc, out, _ = run_jf(
            ["rt", "curl", "-X", "GET", f"/api/repositories/{args.rescueLocal}",
             f"--server-id={args.serverid}"],
            check=False,
        )
        if rc != 0 or not out.strip():
            die(f"rescue local '{args.rescueLocal}' does not exist. Create it first "
                f"(as a local repo of npm package type) then re-run.")
        try:
            repo_data = json.loads(out)
        except json.JSONDecodeError:
            die(f"could not parse repo config for '{args.rescueLocal}'")
        rclass = repo_data.get("rclass", "").lower()
        if rclass != "local":
            die(f"'{args.rescueLocal}' is a '{rclass}' repo, must be 'local' for rescue")
        pkg_type = repo_data.get("packageType", "").lower()
        if pkg_type not in ("npm", ""):
            log(f"WARN: rescue local packageType is '{pkg_type}', expected 'npm'. "
                f"Copies may work but resolution might not.")
        log(f"Rescue local: {args.rescueLocal} (local/{pkg_type or 'unknown'})")

    if args.via_r1:
        upstream_base = ""
        log(f"Mode: via R1 ({jf_cfg.url}/api/npm/{args.sourceRepo}/...)")
    else:
        upstream_base = get_upstream_url(args.sourceRepo, args.serverid)
        log(f"Upstream base: {upstream_base}")

    if args.fromFile:
        log(f"Input: file {args.fromFile}")
        raw_lines = read_input_list(args.fromFile)
        # Accept BOTH pkg@version (from prepop's list output) and artifact paths
        # (from AQL/legacy). Convert to tarball path for the URL; keep original
        # for display so users see the coord they know.
        paths = [(line, coord_to_artifact_path(line)) for line in raw_lines]
        # Report conversion once, in aggregate, so users know what happened
        converted = sum(1 for orig, ap in paths if orig != ap)
        if converted:
            log(f"  Converted {converted}/{len(paths)} pkg@version entries to tarball paths")
    else:
        log(f"Input: AQL against {args.sourceRepo}")
        spec = build_spec(args.sourceRepo, args.downloadedWithin, args.createdWithin)
        results = run_aql_spec_search(spec, args.serverid)
        artifact_paths = aql_to_artifact_paths(results, args.sourceRepo)
        list_path = f"check-list-{timestamp_slug()}.txt"
        with open(list_path, "w") as f:
            for p in artifact_paths:
                f.write(p + "\n")
        log(f"Found {len(artifact_paths)} artifact paths. List: {list_path}")
        # AQL always produces artifact paths; display == path here
        paths = [(p, p) for p in artifact_paths]

    log(f"Checking with concurrency={args.concurrency}...")
    t_start = time.perf_counter()

    report_csv = f"upstream-check-{args.sourceRepo}-{timestamp_slug()}.csv"
    session = requests.Session()
    adapter = requests.adapters.HTTPAdapter(
        pool_connections=args.concurrency,
        pool_maxsize=args.concurrency,
        max_retries=0,
    )
    session.mount("http://", adapter)
    session.mount("https://", adapter)

    io_lock = threading.Lock()
    progress = {"done": 0}
    total = len(paths)
    missing: List[str] = []
    missing_lock = threading.Lock()
    rescue_stats = {"rescued": 0, "failed": 0, "nomatch": 0}

    with ReportWriter(report_csv, ["artifact_path", "upstream_status"]) as writer:
        with ThreadPoolExecutor(max_workers=args.concurrency) as executor:
            futures = {
                executor.submit(
                    check_one, display, artifact_path,
                    upstream_base, args.via_r1,
                    jf_cfg, args.sourceRepo, args.connect_timeout,
                    args.verbose, session, writer, io_lock, progress, total,
                    args.rescueLocal, args.serverid, rescue_stats,
                ): display for (display, artifact_path) in paths
            }
            for future in as_completed(futures):
                display = futures[future]
                try:
                    status = future.result()
                    if status == "404":
                        with missing_lock:
                            missing.append(display)   # log the original coord (readable)
                except Exception as e:
                    with io_lock:
                        log(f"  FAIL  [---]  {display}  (worker exception: {e})")

    elapsed = time.perf_counter() - t_start
    log(f"Complete. {len(paths)} artifacts checked in {elapsed:.1f}s. Report: {report_csv}")

    from collections import Counter
    import csv as _csv
    counts: Counter = Counter()
    with open(report_csv) as f:
        for row in _csv.DictReader(f):
            counts[row["upstream_status"]] += 1
    log("Summary (by status):")
    for s in sorted(counts):
        log(f"  {s:<6} : {counts[s]}")

    if missing:
        missing_txt = f"upstream-missing-{args.sourceRepo}-{timestamp_slug()}.txt"
        with open(missing_txt, "w") as f:
            for m in sorted(set(missing)):
                f.write(m + "\n")
        log(f"{len(set(missing))} artifact(s) missing from upstream: {missing_txt}")
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
