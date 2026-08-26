#!/usr/bin/env python3
"""
prepopulate-r2-pypi.py
------------------------------------------------------------------
Python port of prepopulate-r2-pypi.sh, with ThreadPoolExecutor concurrency.

Two subcommands:
  list         Enumerate PyPI artifacts (.whl / .tar.gz / .zip) in
               R1's cache via AQL and emit pkg==version pairs.
  prepopulate  Run `jf pip download pkg==version --no-deps` for each
               entry through R2. Both metadata (simple/<pkg>/) and the
               pinned artifact get warmed without pulling transitive deps.

HARD PREREQUISITE:
  'pip' on PATH (jf pip shells out to 'pip', not 'pip3').
  On macOS with Homebrew: ln -s /opt/homebrew/bin/pip3 /opt/homebrew/bin/pip
  Verify: pip -V

Concurrency model:
  jf pipc writes .jfrog/projects/pip.yaml in CWD once. Workers read
  this config concurrently (safe — read-only during downloads). Each
  worker downloads to its own tmp directory to avoid file collisions.
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


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Pre-populate R2 (PyPI) via jf pip download --no-deps.",
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
    p_prep.add_argument("--keep-work-dir", action="store_true", dest="keep_work_dir",
                        help="Preserve .jfrog/projects/pip.yaml and downloads dir on exit")
    p_prep.add_argument("--concurrency", type=int, default=8,
                        help="Number of concurrent 'jf pip download' calls (default 8)")
    p_prep.add_argument("--verbose", "-v", action="store_true")

    return p.parse_args()


# ---------- AQL + parsing ----------
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
    """Extract pkg==version from filenames (works for .whl, .tar.gz, .zip)."""
    seen = set()
    for entry in results:
        path = entry.get("path", "")
        filename = path.rsplit("/", 1)[-1]
        for ext in (".tar.gz", ".whl", ".zip"):
            if filename.endswith(ext):
                filename = filename[:-len(ext)]
                break
        m = _FILENAME_RE.match(filename)
        if m:
            seen.add(f"{m.group('name')}=={m.group('version')}")
    return sorted(seen)


# ---------- pip resolver config in CWD (once, not per worker) ----------
def configure_pip_resolver(work_dir: str, targetRepo: str, serverid: str) -> str:
    """
    Run jf pipc in work_dir (CWD by default), returning the path to the
    created pip.yaml. Force-overrides existing pip.yaml so a switch between
    R2 repos across runs takes effect.
    """
    pip_yaml = os.path.join(work_dir, ".jfrog", "projects", "pip.yaml")
    if os.path.exists(pip_yaml):
        prev_repo = "unknown"
        try:
            for line in open(pip_yaml):
                if "repo:" in line:
                    prev_repo = line.split(":")[-1].strip()
                    break
        except OSError:
            pass
        log(f"  Overriding existing config (previous resolver: {prev_repo})")
        try:
            os.remove(pip_yaml)
        except OSError:
            pass

    for cmd_variant in ("pipc", "pip-config"):
        result = subprocess.run(
            ["jf", cmd_variant, f"--repo-resolve={targetRepo}",
             f"--server-id-resolve={serverid}"],
            cwd=work_dir, capture_output=True, text=True, check=False,
        )
        if result.returncode == 0:
            return pip_yaml
    die("could not configure jf pip resolver (tried 'jf pipc' and 'jf pip-config')")


# ---------- prepopulate one coord ----------
def classify_pip_error(stderr: str) -> str:
    text = stderr.lower()
    if "executable file not found" in text or "pip" in text and "not found in" in text:
        return "NOPIP"
    if any(k in text for k in ("no matching distribution", "could not find a version")):
        return "404"
    if any(k in text for k in ("401", "403", "forbidden", "unauthorized")):
        return "403"
    return "FAIL"


# Sentinel: once one worker hits NOPIP, all subsequent workers should stop
_pip_missing = threading.Event()


def prepopulate_one(pkgver: str, work_dir: str, download_dir: str,
                    dry_run: bool, verbose: bool,
                    writer: ReportWriter,
                    io_lock: threading.Lock, progress: dict, total: int) -> None:
    if _pip_missing.is_set():
        return    # short-circuit: pip is missing, all remaining workers noop

    if dry_run:
        with io_lock:
            progress["done"] += 1
            log(f"  DRY   jf pip download {pkgver} --no-deps")
            writer.row({"pkg_version": pkgver, "status": "DRY"})
        return

    # Each worker downloads into its own per-thread subdir to avoid file
    # collisions when multiple pip downloads produce the same filename
    per_worker_dl = os.path.join(download_dir, f"worker-{threading.get_ident()}")
    os.makedirs(per_worker_dl, exist_ok=True)

    result = subprocess.run(
        ["jf", "pip", "download", pkgver, "--no-deps", "-d", per_worker_dl],
        cwd=work_dir, capture_output=True, text=True, check=False,
    )

    # Clean out the downloads to keep disk bounded
    for fn in os.listdir(per_worker_dl):
        try:
            os.remove(os.path.join(per_worker_dl, fn))
        except OSError:
            pass

    if result.returncode == 0:
        status = "200"
    else:
        status = classify_pip_error(result.stderr + result.stdout)

    if status == "NOPIP":
        # First worker to detect this: signal all others to stop and hard-exit
        _pip_missing.set()
        with io_lock:
            log(f"  FAIL  [---]  {pkgver}  (pip binary not found on PATH)")
            log("ERROR: 'jf pip download' shells out to real 'pip' which isn't on PATH.")
            log("       Fix (Homebrew macOS): ln -s /opt/homebrew/bin/pip3 /opt/homebrew/bin/pip")
            log("       Fix (any):            alias pip=pip3  (add to ~/.zshrc)")
            log("       Then rerun this script.")
        sys.exit(1)

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
    log("=== List mode (pypi) ===")
    log(f"Source: {args.sourceRepo}")

    spec = build_spec(args.sourceRepo, args.downloadedWithin, args.createdWithin)
    results = run_aql_spec_search(spec, args.serverid)
    coords = aql_results_to_coords(results)

    out_path = f"pypi-artifacts-{timestamp_slug()}.txt"
    with open(out_path, "w") as f:
        for c in coords:
            f.write(c + "\n")
    log(f"Found {len(coords)} pkg==version entries. List: {out_path}")
    log(f"=== Done. List: {out_path} ===")


def cmd_prepopulate(args: argparse.Namespace) -> None:
    if args.sourceRepo and args.fromFile:
        die("--sourceRepo and --fromFile are mutually exclusive")
    if not args.sourceRepo and not args.fromFile:
        die("one of --sourceRepo or --fromFile is required")

    # Preflight: pip -V must succeed
    if not args.dry_run:
        result = subprocess.run(["pip", "-V"], capture_output=True, text=True, check=False)
        if result.returncode != 0:
            log("ERROR: 'pip -V' failed. 'jf pip download' will not work.")
            pip3_check = subprocess.run(["pip3", "-V"], capture_output=True, text=True, check=False)
            if pip3_check.returncode == 0:
                log("       You have 'pip3' but not 'pip'. Fix (Homebrew macOS):")
                log("       ln -s /opt/homebrew/bin/pip3 /opt/homebrew/bin/pip")
            else:
                log("       Install: python3 -m ensurepip --upgrade")
            log("       Verify with: pip -V")
            sys.exit(1)
        log(f"pip: {result.stdout.strip()}")

    log("=== Prepopulate mode (pypi) ===")
    log(f"Target: {args.targetRepo}")
    log(f"Dry-run: {args.dry_run}")

    if args.sourceRepo:
        log(f"Source: AQL against {args.sourceRepo}")
        spec = build_spec(args.sourceRepo, args.downloadedWithin, args.createdWithin)
        results = run_aql_spec_search(spec, args.serverid)
        coords = aql_results_to_coords(results)
        log(f"Found {len(coords)} pkg==version entries.")
    else:
        log(f"Source: file {args.fromFile}")
        coords = read_input_list(args.fromFile)

    # pip.yaml lands in CWD (matches bash behavior for easy inspection)
    work_dir = os.getcwd()
    log(f"Configuring jf pip resolver in: {work_dir}")
    if not args.dry_run:
        pip_yaml = configure_pip_resolver(work_dir, args.targetRepo, args.serverid)
        log(f"Resolver config written to {pip_yaml}")

    download_dir = tempfile.mkdtemp(prefix="pypi-prepop-")
    log(f"Downloads scratch dir: {download_dir}")

    log(f"Pre-populating {args.targetRepo} with concurrency={args.concurrency}...")
    t_start = time.perf_counter()

    report_csv = f"pypi-prepop-report-{args.targetRepo}-{timestamp_slug()}.csv"
    io_lock = threading.Lock()
    progress = {"done": 0}
    total = len(coords)

    try:
        with ReportWriter(report_csv, ["pkg_version", "status"]) as writer:
            with ThreadPoolExecutor(max_workers=args.concurrency) as executor:
                futures = {
                    executor.submit(
                        prepopulate_one, coord, work_dir, download_dir,
                        args.dry_run, args.verbose, writer,
                        io_lock, progress, total,
                    ): coord for coord in coords
                }
                for future in as_completed(futures):
                    coord = futures[future]
                    try:
                        future.result()
                    except SystemExit:
                        raise
                    except Exception as e:
                        with io_lock:
                            log(f"  FAIL  [---]  {coord}  (worker exception: {e})")
    finally:
        if not args.keep_work_dir:
            # Clean pip.yaml + downloads (but not the whole .jfrog if user had their own)
            pip_yaml = os.path.join(work_dir, ".jfrog", "projects", "pip.yaml")
            if os.path.exists(pip_yaml):
                try:
                    os.remove(pip_yaml)
                except OSError:
                    pass
            try:
                shutil.rmtree(download_dir)
            except OSError:
                pass
        else:
            log(f"Preserved: {work_dir}/.jfrog/projects/pip.yaml")
            log(f"Preserved: {download_dir}")

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
