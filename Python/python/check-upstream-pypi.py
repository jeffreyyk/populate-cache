#!/usr/bin/env python3
"""
check-upstream-pypi.py
------------------------------------------------------------------
Python port of check-upstream-pypi.sh, with ThreadPoolExecutor concurrency.

Given a list of pkg==version pairs, GET each package's PEP 503 simple
index (from upstream or from R1 via tenant API), then grep the response
for the specific version filename prefix to confirm the version exists.

Two flavors of "missing":
  MISS_PKG  → simple index returns 404: entire package gone
  MISS_VER  → index returns 200 but version substring not present:
              this specific version yanked

Both collapse to '404' in the CSV so downstream rescue-local filtering
only needs one status; the label difference is only for humans.
"""

import argparse
import json
import re
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import List, Optional

import requests

from prepop_lib import (
    JFConfig, ReportWriter,
    die, get_jf_config, log, parse_duration_to_cutoff,
    read_input_list, run_aql_spec_search, run_jf,
    timestamp_slug, verify_serverid,
)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Check whether pkg==version pairs still exist on PyPI upstream.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--serverid", required=True)
    p.add_argument("--sourceRepo", required=True)
    p.add_argument("--fromFile", help="Read pkg==version list from a file")
    p.add_argument("--downloadedWithin", help="AQL filter (e.g. 1y)")
    p.add_argument("--createdWithin", help="AQL filter (e.g. 1y)")
    p.add_argument("--via-r1", action="store_true", dest="via_r1",
                   help="Route through tenant's PyPI API (Zscaler workaround)")
    p.add_argument("--connect-timeout", type=float, default=10.0,
                   dest="connect_timeout")
    p.add_argument("--concurrency", type=int, default=8,
                   help="Number of concurrent GET requests (default 8)")
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
    # files.pythonhosted.org is CDN-only (no simple index); swap to pypi.org
    if "files.pythonhosted.org" in url:
        log("  Note: R1 upstream is files.pythonhosted.org (CDN, not index).")
        log("        Using https://pypi.org for the simple-index check instead.")
        url = "https://pypi.org"
    return url


def build_spec(sourceRepo: str, downloadedWithin: str = None,
               createdWithin: str = None) -> dict:
    conditions = {
        "$and": [
            {"repo": f"{sourceRepo}-cache"},
            {"type": "file"},
            {"$or": [
                {"name": {"$match": "*.whl"}},
                {"name": {"$match": "*.tar.gz"}},
                {"name": {"$match": "*.zip"}},
            ]},
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


_FILENAME_RE = re.compile(r"^(?P<name>.+?)-(?P<version>[0-9][^-]*)(?:-|$)")


def aql_results_to_coords(results: list) -> List[str]:
    """Extract pkg==version from artifact filenames (works for .whl, .tar.gz, .zip)."""
    seen = set()
    for entry in results:
        path = entry.get("path", "")
        filename = path.rsplit("/", 1)[-1]
        # Strip archive extension
        for ext in (".tar.gz", ".whl", ".zip"):
            if filename.endswith(ext):
                filename = filename[:-len(ext)]
                break
        m = _FILENAME_RE.match(filename)
        if m:
            seen.add(f"{m.group('name')}=={m.group('version')}")
    return sorted(seen)


# PEP 503: lowercase and collapse runs of [-_.] to single '-'
_NORMALIZE_RE = re.compile(r"[-_.]+")


def normalize_pkg_name(name: str) -> str:
    return _NORMALIZE_RE.sub("-", name.lower())


def check_one(pkgver: str, upstream_base: str, jf_cfg: JFConfig,
              via_r1: bool, sourceRepo: str, timeout: float,
              verbose: bool, session: requests.Session,
              writer: ReportWriter,
              io_lock: threading.Lock, progress: dict, total: int) -> str:
    """
    GET simple index for pkg; check response body for version filename prefix.
    Returns CSV status code (200/404/401/000).
    """
    pkg, _, version = pkgver.partition("==")
    norm_pkg = normalize_pkg_name(pkg)

    if via_r1:
        url = f"{jf_cfg.url}/api/pypi/{sourceRepo}/simple/{norm_pkg}/"
        headers = jf_cfg.auth_headers
        auth = jf_cfg.basic_auth
    else:
        url = f"{upstream_base}/simple/{norm_pkg}/"
        headers = {}
        auth = None

    status = "000"
    error = ""
    body = ""
    elapsed = 0.0
    t0 = time.perf_counter()
    try:
        resp = session.get(url, headers=headers, auth=auth, timeout=timeout,
                           allow_redirects=True)
        status = str(resp.status_code)
        body = resp.text if status == "200" else ""
        elapsed = resp.elapsed.total_seconds()
    except requests.exceptions.RequestException as e:
        error = str(e)[:80]
    total_time = time.perf_counter() - t0

    if status == "200":
        # Look for '<norm_pkg>-<version>-' (wheels) or '<norm_pkg>-<version>.' (sdists)
        if f"{norm_pkg}-{version}-" in body or f"{norm_pkg}-{version}." in body:
            label = f"OK    [200]  {pkgver}"
            csv_status = "200"
        else:
            label = f"MISS  [200/yanked]  {pkgver}  (upstream has {norm_pkg} but not version {version})"
            csv_status = "404"    # collapse for consistent rescue-local filter
    elif status == "404":
        label = f"MISS  [404]  {pkgver}  (package not in upstream)"
        csv_status = "404"
    elif status in ("401", "403"):
        hint = "check server-id auth" if via_r1 else "likely corporate proxy — try --via-r1"
        label = f"AUTH  [{status}]  {pkgver}  ({hint})"
        csv_status = status
    elif status == "000":
        label = f"FAIL  [---]  {pkgver}  ({error})"
        csv_status = "000"
    else:
        label = f"?     [{status}]  {pkgver}"
        csv_status = status

    with io_lock:
        progress["done"] += 1
        counter = f"[{progress['done']}/{total}]"
        log(f"  {counter}  {label}")
        if verbose:
            log(f"         timing: elapsed={elapsed:.3f} total={total_time:.3f}")
        writer.row({"pkg": pkg, "version": version, "upstream_status": csv_status})
    return csv_status


def main() -> None:
    args = parse_args()
    log("=== Upstream check (pypi) ===")
    log(f"Source repo: {args.sourceRepo}")

    verify_serverid(args.serverid)
    jf_cfg = get_jf_config(args.serverid)

    if args.via_r1:
        upstream_url = ""
        log(f"Mode: via R1 ({jf_cfg.url}/api/pypi/{args.sourceRepo}/simple/...)")
    else:
        upstream_url = get_upstream_url(args.sourceRepo, args.serverid)
        log(f"Upstream: {upstream_url}")

    if args.fromFile:
        log(f"Input: file {args.fromFile}")
        coords = read_input_list(args.fromFile)
    else:
        log(f"Input: AQL against {args.sourceRepo}")
        spec = build_spec(args.sourceRepo, args.downloadedWithin, args.createdWithin)
        results = run_aql_spec_search(spec, args.serverid)
        coords = aql_results_to_coords(results)
        list_path = f"check-pypi-list-{timestamp_slug()}.txt"
        with open(list_path, "w") as f:
            for c in coords:
                f.write(c + "\n")
        log(f"Found {len(coords)} pkg==version entries. List: {list_path}")

    log(f"Checking with concurrency={args.concurrency}...")
    t_start = time.perf_counter()

    report_csv = f"upstream-check-pypi-{args.sourceRepo}-{timestamp_slug()}.csv"
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
    total = len(coords)
    missing: List[str] = []
    missing_lock = threading.Lock()

    with ReportWriter(report_csv, ["pkg", "version", "upstream_status"]) as writer:
        with ThreadPoolExecutor(max_workers=args.concurrency) as executor:
            futures = {
                executor.submit(
                    check_one, coord, upstream_url, jf_cfg, args.via_r1,
                    args.sourceRepo, args.connect_timeout, args.verbose,
                    session, writer, io_lock, progress, total,
                ): coord for coord in coords
            }
            for future in as_completed(futures):
                coord = futures[future]
                try:
                    status = future.result()
                    if status == "404":
                        with missing_lock:
                            missing.append(coord)
                except Exception as e:
                    with io_lock:
                        log(f"  FAIL  [---]  {coord}  (worker exception: {e})")

    elapsed = time.perf_counter() - t_start
    log(f"Complete. {len(coords)} pkg==version checked in {elapsed:.1f}s. Report: {report_csv}")

    from collections import Counter
    import csv as _csv
    counts: Counter = Counter()
    with open(report_csv) as f:
        for row in _csv.DictReader(f):
            counts[row["upstream_status"]] += 1
    log("Summary (by status):")
    for s in sorted(counts):
        log(f"  {s:<8} : {counts[s]}")

    if missing:
        missing_txt = f"upstream-missing-pypi-{args.sourceRepo}-{timestamp_slug()}.txt"
        with open(missing_txt, "w") as f:
            for m in sorted(set(missing)):
                f.write(m + "\n")
        log(f"{len(set(missing))} pkg==version missing from upstream: {missing_txt}")
        log("Feed this file into the rescue-local remediation step.")
    else:
        log("No missing packages detected. Nothing to remediate.")

    log("=== Done ===")


if __name__ == "__main__":
    main()
