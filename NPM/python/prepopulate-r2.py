#!/usr/bin/env python3
"""
prepopulate-r2.py  (NPM)
------------------------------------------------------------------
Python port of prepopulate-r2.sh, with ThreadPoolExecutor concurrency.

Two subcommands:
  list         Enumerate .tgz artifacts in R1's cache via AQL and
               emit pkg@version pairs.
  prepopulate  Run `jf npm pack pkg@version` for each entry through
               R2. Pack fetches both metadata (.npm/<pkg>/package.json)
               and tarball (.tgz) without pulling transitive deps.

Concurrency model:
  Each worker gets its own temp directory (jf npmc writes .jfrog/
  config there, and jf npm pack writes the resulting .tgz there).
  This avoids collisions when multiple workers run 'jf npm pack' in
  parallel.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import List

from prepop_lib import (
    ReportWriter,
    die, log, parse_duration_to_cutoff, read_input_list,
    run_aql_spec_search, timestamp_slug, verify_serverid,
)


# ---------- CLI ----------
def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Pre-populate R2 (npm) via jf npm pack, or list R1's cached tarballs.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--serverid", required=True)

    p_list = sub.add_parser("list", parents=[common])
    p_list.add_argument("--sourceRepo", required=True)
    p_list.add_argument("--downloadedWithin")
    p_list.add_argument("--createdWithin")

    p_prep = sub.add_parser("prepopulate", parents=[common])
    p_prep.add_argument("--targetRepo", required=True)
    p_prep.add_argument("--sourceRepo")
    p_prep.add_argument("--fromFile")
    p_prep.add_argument("--downloadedWithin")
    p_prep.add_argument("--createdWithin")
    p_prep.add_argument("--dry-run", action="store_true", dest="dry_run")
    p_prep.add_argument("--concurrency", type=int, default=8,
                        help="Number of concurrent 'jf npm pack' invocations (default 8)")
    p_prep.add_argument("--verbose", "-v", action="store_true")

    return p.parse_args()


# ---------- AQL + parsing ----------
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


# Path shape: eslint/-/eslint-8.57.0.tgz -> eslint@8.57.0
#             @babel/code-frame/-/code-frame-7.29.7.tgz -> @babel/code-frame@7.29.7
_PATH_RE = re.compile(r"^(?P<pkg>.+)/-/(?P<filename>[^/]+)\.tgz$")
_NAME_VER_RE = re.compile(r"^(?P<n>.+)-(?P<v>[0-9][^-]*.*)$")


def aql_results_to_coords(results: list, source_repo: str) -> List[str]:
    prefix = f"{source_repo}-cache/"
    seen = set()
    for entry in results:
        path = entry.get("path", "")
        if path.startswith(prefix):
            path = path[len(prefix):]
        m = _PATH_RE.match(path)
        if not m:
            continue
        pkg = m.group("pkg")
        nv = _NAME_VER_RE.match(m.group("filename"))
        if not nv:
            continue
        seen.add(f"{pkg}@{nv.group('v')}")
    return sorted(seen)


# ---------- npm resolver config in each worker's temp dir ----------
def configure_npm_resolver(work_dir: str, targetRepo: str, serverid: str) -> None:
    """Run jf npmc (or jf npm-config on newer CLIs) in work_dir."""
    for cmd_variant in ("npmc", "npm-config"):
        result = subprocess.run(
            ["jf", cmd_variant, f"--repo-resolve={targetRepo}",
             f"--server-id-resolve={serverid}"],
            cwd=work_dir, capture_output=True, text=True, check=False,
        )
        if result.returncode == 0:
            return
    die("could not configure jf npm resolver (tried 'jf npmc' and 'jf npm-config')")


# ---------- prepopulate one coord ----------
def classify_npm_error(stderr: str) -> str:
    text = stderr.lower()
    if any(k in text for k in ("404", "not found", "no matching version",
                                "is not in the npm registry")):
        return "404"
    if any(k in text for k in ("401", "403", "forbidden", "unauthorized",
                                "eauth", "denied")):
        return "403"
    return "FAIL"


def prepopulate_one(pkgver: str, target_repo: str, serverid: str, dry_run: bool,
                    verbose: bool, base_work_dir: str,
                    writer: ReportWriter,
                    io_lock: threading.Lock, progress: dict, total: int) -> None:
    """
    Runs `jf npm pack pkgver` in an isolated per-worker subdirectory of
    base_work_dir. Each worker gets its own subdir with its own .jfrog config
    and .tgz output, so multiple workers can run concurrently without
    stepping on each other.
    """
    if dry_run:
        with io_lock:
            progress["done"] += 1
            log(f"  DRY   jf npm pack {pkgver}")
            writer.row({"pkg_version": pkgver, "status": "DRY"})
        return

    # Per-worker subdir. Named after the thread; each subdir is set up
    # exactly once per worker thread (lazily on first call).
    worker_dir = os.path.join(base_work_dir, f"worker-{threading.get_ident()}")
    if not os.path.exists(worker_dir):
        os.makedirs(worker_dir, exist_ok=True)
        configure_npm_resolver(worker_dir, target_repo, serverid)

    result = subprocess.run(
        ["jf", "npm", "pack", pkgver],
        cwd=worker_dir, capture_output=True, text=True, check=False,
    )

    # Remove the .tgz that jf npm pack left in the worker dir (keeps disk bounded)
    for fn in os.listdir(worker_dir):
        if fn.endswith(".tgz"):
            try:
                os.remove(os.path.join(worker_dir, fn))
            except OSError:
                pass

    if result.returncode == 0:
        status = "200"
    else:
        status = classify_npm_error(result.stderr + result.stdout)

    err_line = ""
    if status != "200":
        combined = (result.stderr + result.stdout).strip()
        if combined:
            err_line = combined.splitlines()[-1][:120]

    labels = {
        "200":  f"OK    [200]  {pkgver}",
        "403":  f"BLOCK [403]  {pkgver}  (Curation denied or auth failed)",
        "404":  f"MISS  [404]  {pkgver}  (not in upstream)",
        "FAIL": f"FAIL  [---]  {pkgver}  ({err_line})",
    }

    with io_lock:
        progress["done"] += 1
        counter = f"[{progress['done']}/{total}]"
        log(f"  {counter}  {labels.get(status, f'?     [{status}]  {pkgver}')}")
        if verbose and err_line and status != "200":
            log(f"         {err_line}")
        writer.row({"pkg_version": pkgver, "status": status})


# ---------- subcommands ----------
def cmd_list(args: argparse.Namespace) -> None:
    log("=== List mode (npm) ===")
    log(f"Source: {args.sourceRepo}")

    spec = build_spec(args.sourceRepo, args.downloadedWithin, args.createdWithin)
    results = run_aql_spec_search(spec, args.serverid)
    coords = aql_results_to_coords(results, args.sourceRepo)

    out_path = f"npm-artifacts-{timestamp_slug()}.txt"
    with open(out_path, "w") as f:
        for c in coords:
            f.write(c + "\n")
    log(f"Found {len(coords)} pkg@version entries. List: {out_path}")
    log(f"=== Done. List: {out_path} ===")


def cmd_prepopulate(args: argparse.Namespace) -> None:
    if args.sourceRepo and args.fromFile:
        die("--sourceRepo and --fromFile are mutually exclusive")
    if not args.sourceRepo and not args.fromFile:
        die("one of --sourceRepo or --fromFile is required")

    # Preflight: npm binary must exist for `jf npm pack` to work
    if not args.dry_run:
        result = subprocess.run(["npm", "-v"], capture_output=True, text=True, check=False)
        if result.returncode != 0:
            die("'npm' binary not found on PATH. Install Node.js first (brew install node).")
        log(f"npm: v{result.stdout.strip()}")

    log("=== Prepopulate mode (npm) ===")
    log(f"Target: {args.targetRepo}")
    log(f"Dry-run: {args.dry_run}")

    if args.sourceRepo:
        log(f"Source: AQL against {args.sourceRepo}")
        spec = build_spec(args.sourceRepo, args.downloadedWithin, args.createdWithin)
        results = run_aql_spec_search(spec, args.serverid)
        coords = aql_results_to_coords(results, args.sourceRepo)
        log(f"Found {len(coords)} pkg@version entries.")
    else:
        log(f"Source: file {args.fromFile}")
        coords = read_input_list(args.fromFile)

    if args.dry_run:
        log("DRY RUN - no jf npm pack commands will run")

    log(f"Pre-populating {args.targetRepo} with concurrency={args.concurrency}...")
    t_start = time.perf_counter()

    # One base work dir; each worker thread gets its own subdir inside it
    base_work_dir = tempfile.mkdtemp(prefix="npm-prepop-")
    log(f"Scratch dir: {base_work_dir}")

    report_csv = f"prepop-report-{args.targetRepo}-{timestamp_slug()}.csv"
    io_lock = threading.Lock()
    progress = {"done": 0}
    total = len(coords)

    try:
        with ReportWriter(report_csv, ["pkg_version", "status"]) as writer:
            with ThreadPoolExecutor(max_workers=args.concurrency) as executor:
                futures = {
                    executor.submit(
                        prepopulate_one, coord, args.targetRepo, args.serverid,
                        args.dry_run, args.verbose, base_work_dir, writer,
                        io_lock, progress, total,
                    ): coord for coord in coords
                }
                for future in as_completed(futures):
                    coord = futures[future]
                    try:
                        future.result()
                    except Exception as e:
                        with io_lock:
                            log(f"  FAIL  [---]  {coord}  (worker exception: {e})")
    finally:
        # Cleanup scratch
        try:
            shutil.rmtree(base_work_dir)
        except OSError:
            pass

    elapsed = time.perf_counter() - t_start
    log(f"Complete. {len(coords)} entries processed in {elapsed:.1f}s. Report: {report_csv}")

    from collections import Counter
    import csv as _csv
    counts: Counter = Counter()
    with open(report_csv) as f:
        for row in _csv.DictReader(f):
            counts[row["status"]] += 1
    log("Summary:")
    for s in sorted(counts):
        log(f"  {s:<6} : {counts[s]}")

    log("=== Done ===")


def main() -> None:
    args = parse_args()
    verify_serverid(args.serverid)
    if args.cmd == "list":
        cmd_list(args)
    elif args.cmd == "prepopulate":
        cmd_prepopulate(args)


if __name__ == "__main__":
    main()
