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
import sys
from typing import List, Tuple

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


def check_one(coord: str, upstream_base: str, timeout: float, verbose: bool,
              session: requests.Session, writer: ReportWriter) -> str:
    """HEAD each expected file for the coord. Return the rolled-up overall status."""
    is_pom_only = coord.endswith(":pom")
    display = f"{coord} (POM-only)" if is_pom_only else coord

    files = coord_to_files(coord)
    if not files:
        log(f"  ?     [---]  {coord}  (unparseable coord)")
        return "PARSE"

    overall = "200"
    status_bits = []
    for artifact_type, rel_path in files:
        url = f"{upstream_base}/{rel_path}"
        result = head_with_timing(url, timeout=timeout, verbose=verbose, session=session)
        status = result.status
        status_bits.append(f"{artifact_type}={status}")
        # Roll up worst status
        if status == "000":
            overall = "FAIL"
        elif status in ("401", "403") and overall not in ("FAIL",):
            overall = "AUTH"
        elif status == "404" and overall in ("200", "AUTH"):
            overall = "404"

        writer.row({
            "coord": coord,
            "artifact_type": artifact_type,
            "upstream_status": status,
        })
        if verbose and result.timing_detail:
            log(f"         {artifact_type} timing: {result.timing_detail}")

    status_line = " ".join(status_bits)
    label_map = {
        "200":  f"OK    [200]  {display}  ({status_line})",
        "AUTH": f"AUTH  [401/403]  {display}  ({status_line})  (upstream requires auth)",
        "404":  f"MISS  [404]  {display}  ({status_line})  (missing from upstream)",
        "FAIL": f"FAIL  [---]  {display}  ({status_line})",
    }
    log(f"  {label_map.get(overall, f'?     [{overall}]  {display}  ({status_line})')}")
    return overall


def main() -> None:
    args = parse_args()

    log("=== Upstream check (maven) ===")
    log(f"Source repo: {args.sourceRepo}")

    verify_serverid(args.serverid)

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

    log("Checking coordinates...")

    report_csv = f"upstream-check-maven-{args.sourceRepo}-{timestamp_slug()}.csv"
    missing_txt = f"upstream-missing-maven-{args.sourceRepo}-{timestamp_slug()}.txt"

    session = requests.Session()
    missing_coords: List[str] = []

    with ReportWriter(report_csv, ["coord", "artifact_type", "upstream_status"]) as writer:
        for coord in coords:
            overall = check_one(
                coord, upstream_base,
                timeout=args.connect_timeout,
                verbose=args.verbose,
                session=session,
                writer=writer,
            )
            if overall == "404":
                missing_coords.append(coord)

    log(f"Complete. {len(coords)} coordinates checked. Report: {report_csv}")

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
        log("Feed this file into the rescue-local remediation step.")
    else:
        log("No missing artifacts detected. Nothing to remediate.")

    log("=== Done ===")


if __name__ == "__main__":
    main()
