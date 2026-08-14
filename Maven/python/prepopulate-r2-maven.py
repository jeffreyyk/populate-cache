#!/usr/bin/env python3
"""
prepopulate-r2-maven.py
------------------------------------------------------------------
Python port of prepopulate-r2-maven.sh.

Two subcommands:
  list         Enumerate .jar+.pom artifacts in R1's cache via AQL and
               emit groupId:artifactId:version coordinates (with :pom
               suffix for POM-only artifacts).
  prepopulate  HEAD each artifact's .jar and .pom (and optionally
               maven-metadata.xml) through R2 to warm R2's cache and
               trigger Curation evaluation.
"""

import argparse
import re
import sys
from typing import List, Tuple

import requests

from prepop_lib import (
    JFConfig, ReportWriter,
    die, get_jf_config, head_with_timing, log, log_verbose,
    parse_duration_to_cutoff, print_status_summary, read_input_list,
    run_aql_spec_search, timestamp_slug, verify_serverid,
)


# ---------- Argument parsing ----------
def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Pre-populate R2 (Maven) or list R1's cached artifacts.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--serverid", required=True)

    p_list = sub.add_parser("list", parents=[common], help="Enumerate R1's cached coords")
    p_list.add_argument("--sourceRepo", required=True)
    p_list.add_argument("--downloadedWithin")
    p_list.add_argument("--createdWithin")
    p_list.add_argument("--includeSources", action="store_true")
    p_list.add_argument("--includeJavadoc", action="store_true")

    p_prep = sub.add_parser("prepopulate", parents=[common], help="HEAD each coord through R2")
    p_prep.add_argument("--targetRepo", required=True)
    p_prep.add_argument("--sourceRepo")
    p_prep.add_argument("--fromFile")
    p_prep.add_argument("--downloadedWithin")
    p_prep.add_argument("--createdWithin")
    p_prep.add_argument("--includeSources", action="store_true")
    p_prep.add_argument("--includeJavadoc", action="store_true")
    p_prep.add_argument("--withMetadata", action="store_true",
                        help="Also HEAD maven-metadata.xml at artifact level")
    p_prep.add_argument("--dry-run", action="store_true", dest="dry_run")
    p_prep.add_argument("--connect-timeout", type=float, default=10.0,
                        dest="connect_timeout")
    p_prep.add_argument("--verbose", "-v", action="store_true")

    return p.parse_args()


# ---------- Spec + parsing ----------
def build_spec(source_repo: str, include_sources: bool, include_javadoc: bool,
               downloaded_within: str = None, created_within: str = None) -> dict:
    conditions = {
        "$and": [
            {"repo": f"{source_repo}-cache"},
            {"type": "file"},
            {"$or": [
                {"name": {"$match": "*.jar"}},
                {"name": {"$match": "*.pom"}},
            ]},
        ]
    }
    if not include_sources:
        conditions["$and"].append({"name": {"$nmatch": "*-sources.jar"}})
    if not include_javadoc:
        conditions["$and"].append({"name": {"$nmatch": "*-javadoc.jar"}})
    if downloaded_within:
        conditions["$and"].append(
            {"stat.downloaded": {"$gt": parse_duration_to_cutoff(downloaded_within)}}
        )
        log(f"Filter: stat.downloaded > within {downloaded_within}")
    if created_within:
        conditions["$and"].append(
            {"created": {"$gt": parse_duration_to_cutoff(created_within)}}
        )
        log(f"Filter: created > within {created_within}")
    return {"files": [{"aql": {"items.find": conditions}}]}


_PATH_RE = re.compile(r"^(?P<pp>.+)/[^/]+\.(?P<ext>jar|pom)$")


def aql_results_to_coords(results: list, source_repo: str) -> List[str]:
    """Group AQL results by g:a:v; emit ':pom' suffix if only .pom exists."""
    prefix = f"{source_repo}-cache/"
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
        coords.append(gav if "jar" in exts else f"{gav}:pom")
    return coords


def coord_to_files(coord: str) -> Tuple[str, str, str, bool]:
    """
    Return (jar_path, pom_path, meta_path, is_pom_only).
    jar_path is empty if the coord is POM-only.
    """
    parts = coord.split(":")
    if len(parts) not in (3, 4):
        return ("", "", "", False)
    group_id, artifact_id, version = parts[0], parts[1], parts[2]
    is_pom_only = len(parts) == 4 and parts[3] == "pom"

    group_path = group_id.replace(".", "/")
    base = f"{group_path}/{artifact_id}/{version}/{artifact_id}-{version}"
    meta = f"{group_path}/{artifact_id}/maven-metadata.xml"

    return ("" if is_pom_only else f"{base}.jar", f"{base}.pom", meta, is_pom_only)


# ---------- list subcommand ----------
def cmd_list(args: argparse.Namespace) -> None:
    log("=== List mode (maven) ===")
    log(f"Source: {args.sourceRepo}")
    log(f"Include sources: {args.includeSources}   javadoc: {args.includeJavadoc}")

    spec = build_spec(
        args.sourceRepo, args.includeSources, args.includeJavadoc,
        args.downloadedWithin, args.createdWithin,
    )
    results = run_aql_spec_search(spec, args.serverid)
    coords = aql_results_to_coords(results, args.sourceRepo)

    out_path = f"maven-artifacts-{timestamp_slug()}.txt"
    with open(out_path, "w") as f:
        for c in coords:
            f.write(c + "\n")

    regular = sum(1 for c in coords if not c.endswith(":pom"))
    pom_only = len(coords) - regular
    log(f"Found {len(coords)} Maven coordinates: {regular} regular, {pom_only} POM-only. List: {out_path}")
    log(f"=== Done. List: {out_path} ===")


# ---------- prepopulate subcommand ----------
def prepopulate_one(coord: str, target_repo: str, jf_cfg: JFConfig,
                    with_metadata: bool, dry_run: bool, timeout: float,
                    verbose: bool, session: requests.Session,
                    writer: ReportWriter) -> None:
    jar_path, pom_path, meta_path, is_pom_only = coord_to_files(coord)
    if not pom_path:
        log(f"  ?     [---]  {coord}  (unparseable coord)")
        return

    files_to_head: List[Tuple[str, str]] = [("pom", pom_path)]
    if not is_pom_only:
        files_to_head.append(("jar", jar_path))
    if with_metadata:
        files_to_head.append(("metadata", meta_path))

    display = f"{coord} (POM-only)" if is_pom_only else coord

    if dry_run:
        for _, path in files_to_head:
            log(f"  DRY   HEAD {jf_cfg.url}/{target_repo}/{path}")
        for artifact_type, _ in files_to_head:
            writer.row({"coord": coord, "artifact_type": artifact_type, "http_status": "DRY"})
        return

    overall = "200"
    status_bits = []
    for artifact_type, rel_path in files_to_head:
        url = f"{jf_cfg.url}/{target_repo}/{rel_path}"
        result = head_with_timing(
            url,
            headers=jf_cfg.auth_headers,
            auth=jf_cfg.basic_auth,
            timeout=timeout,
            verbose=verbose,
            session=session,
        )
        status = result.status
        status_bits.append(f"{artifact_type}={status}")

        if status == "000":
            overall = "FAIL"
        elif status == "403" and overall not in ("FAIL",):
            overall = "403"
        elif status == "404" and overall == "200":
            overall = "404"

        writer.row({"coord": coord, "artifact_type": artifact_type, "http_status": status})
        if verbose and result.timing_detail:
            log(f"         {artifact_type} {status}: {result.timing_detail}")

    status_line = " ".join(status_bits)
    labels = {
        "200":  f"OK    [200]  {display}  ({status_line})",
        "403":  f"BLOCK [403]  {display}  ({status_line})  (Curation denied)",
        "404":  f"MISS  [404]  {display}  ({status_line})  (not in upstream)",
        "FAIL": f"FAIL  [---]  {display}  ({status_line})",
    }
    log(f"  {labels.get(overall, f'?     [{overall}]  {display}  ({status_line})')}")


def cmd_prepopulate(args: argparse.Namespace) -> None:
    if args.sourceRepo and args.fromFile:
        die("--sourceRepo and --fromFile are mutually exclusive")
    if not args.sourceRepo and not args.fromFile:
        die("one of --sourceRepo or --fromFile is required")

    log("=== Prepopulate mode (maven) ===")
    log(f"Target: {args.targetRepo}")
    log(f"With metadata: {args.withMetadata}")
    log(f"Dry-run: {args.dry_run}")

    jf_cfg = get_jf_config(args.serverid)

    if args.sourceRepo:
        log(f"Source: AQL against {args.sourceRepo}")
        spec = build_spec(
            args.sourceRepo, args.includeSources, args.includeJavadoc,
            args.downloadedWithin, args.createdWithin,
        )
        results = run_aql_spec_search(spec, args.serverid)
        coords = aql_results_to_coords(results, args.sourceRepo)
        log(f"Found {len(coords)} Maven coordinates.")
    else:
        log(f"Source: file {args.fromFile}")
        coords = read_input_list(args.fromFile)

    if args.dry_run:
        log("DRY RUN - no requests will hit R2")

    meta_suffix = " + maven-metadata.xml" if args.withMetadata else ""
    log(f"Pre-populating {args.targetRepo} via HEAD (.jar + .pom{meta_suffix})...")

    report_csv = f"maven-prepop-report-{args.targetRepo}-{timestamp_slug()}.csv"
    session = requests.Session()

    with ReportWriter(report_csv, ["coord", "artifact_type", "http_status"]) as writer:
        for coord in coords:
            prepopulate_one(
                coord, args.targetRepo, jf_cfg,
                with_metadata=args.withMetadata,
                dry_run=args.dry_run,
                timeout=args.connect_timeout,
                verbose=args.verbose,
                session=session,
                writer=writer,
            )

    log(f"Complete. {len(coords)} coordinates processed. Report: {report_csv}")

    log("Summary (by artifact_type + status):")
    import csv as _csv
    from collections import Counter
    counts: Counter = Counter()
    with open(report_csv) as f:
        for row in _csv.DictReader(f):
            counts[f"{row['artifact_type']}/{row['http_status']}"] += 1
    for key in sorted(counts):
        log(f"  {key:<15} : {counts[key]}")

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
