#!/usr/bin/env python3
"""
prepopulate-r2-docker.py
------------------------------------------------------------------
Python port of prepopulate-r2-docker.sh.

Two subcommands:
  list         Enumerate R1's cached tag folders, fetch each fat manifest
               via Docker Registry v2 API, cross-reference with R1's
               cached sha256__ digest folders, and emit image:tag#os/arch
               entries for each platform R1 actually has cached.
               Falls back to image:tag (no platform) when no cached
               digest matches the current fat manifest.

  prepopulate  For each entry, shell out to `jf docker pull --platform`
               through R2. Attestations and orphaned digests handled
               correctly (they'd have platform=unknown/unknown and get
               skipped in list).
"""

import argparse
import json
import re
import subprocess
import sys
from typing import List, Optional, Set, Tuple

import requests

from prepop_lib import (
    JFConfig, ReportWriter,
    die, get_jf_config, log, log_verbose, parse_duration_to_cutoff,
    read_input_list, run_aql_spec_search, run_jf,
    timestamp_slug, verify_serverid,
)


ACCEPT_MANIFEST = (
    "application/vnd.oci.image.index.v1+json,"
    "application/vnd.docker.distribution.manifest.list.v2+json,"
    "application/vnd.docker.distribution.manifest.v2+json,"
    "application/vnd.oci.image.manifest.v1+json"
)


# ---------- CLI ----------
def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="List or prepopulate Docker images through R2.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--serverid", required=True)

    p_list = sub.add_parser("list", parents=[common], help="Enumerate cached tags with platforms")
    p_list.add_argument("--sourceRepo", required=True)
    p_list.add_argument("--createdWithin")
    p_list.add_argument("--verbose", "-v", action="store_true")

    p_prep = sub.add_parser("prepopulate", parents=[common])
    p_prep.add_argument("--targetRepo", required=True)
    p_prep.add_argument("--sourceRepo")
    p_prep.add_argument("--fromFile")
    p_prep.add_argument("--createdWithin")
    p_prep.add_argument("--registryHost", help="Docker registry hostname (default: derived from JFrog URL)")
    p_prep.add_argument("--keep-local", action="store_true", dest="keep_local",
                        help="Keep pulled images in local docker (default: docker rmi after each pull)")
    p_prep.add_argument("--dry-run", action="store_true", dest="dry_run")
    p_prep.add_argument("--verbose", "-v", action="store_true")

    return p.parse_args()


# ---------- Spec + cached-digest enumeration ----------
def build_tag_spec(sourceRepo: str, createdWithin: Optional[str]) -> dict:
    conditions = {
        "$and": [
            {"repo": f"{sourceRepo}-cache"},
            {"type": "file"},
            {"$or": [
                {"name": {"$eq": "manifest.json"}},
                {"name": {"$eq": "list.manifest.json"}},
            ]},
            {"path": {"$nmatch": "*sha256__*"}},
            {"path": {"$nmatch": ".jfrog*"}},
        ]
    }
    if createdWithin:
        conditions["$and"].append(
            {"created": {"$gt": parse_duration_to_cutoff(createdWithin)}}
        )
        log(f"Filter: created > within {createdWithin}")
    return {"files": [{"aql": {"items.find": conditions}}]}


def build_cached_digests_spec(sourceRepo: str) -> dict:
    """Find all sha256__ arch-manifest folders to know which platforms R1 has."""
    return {
        "files": [{
            "aql": {
                "items.find": {
                    "$and": [
                        {"repo": f"{sourceRepo}-cache"},
                        {"type": "file"},
                        {"name": {"$eq": "manifest.json"}},
                        {"path": {"$match": "*sha256__*"}},
                    ]
                }
            }
        }]
    }


def load_cached_digests(sourceRepo: str, serverid: str) -> Set[str]:
    """Return a set of 'image@sha256:xxx' strings for all cached arch manifests."""
    spec = build_cached_digests_spec(sourceRepo)
    results = run_aql_spec_search(spec, serverid)
    prefix = f"{sourceRepo}-cache/"
    digests = set()
    for r in results:
        path = r.get("path", "")
        if path.startswith(prefix):
            path = path[len(prefix):]
        # Path shape: <image>/sha256__<hash>/manifest.json
        m = re.match(r"^(?P<image>.+)/sha256__(?P<hash>[a-f0-9]+)/manifest\.json$", path)
        if m:
            digests.add(f"{m.group('image')}@sha256:{m.group('hash')}")
    return digests


# ---------- Fat manifest fetch ----------
def fetch_fat_manifest(image: str, tag: str, sourceRepo: str, serverid: str) -> Optional[list]:
    """Fetch the fat manifest via Docker Registry v2 API; return the .manifests[] list."""
    endpoint = f"/api/docker/{sourceRepo}/v2/{image}/manifests/{tag}"
    rc, out, _ = run_jf(
        ["rt", "curl", "-s", endpoint,
         "-H", f"Accept: {ACCEPT_MANIFEST}",
         f"--server-id={serverid}"],
        check=False,
    )
    if not out.strip():
        return None
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return None
    return data.get("manifests")


# ---------- list subcommand ----------
def cmd_list(args: argparse.Namespace) -> None:
    log("=== List mode (docker) ===")
    log(f"Source: {args.sourceRepo}")

    log(f"Searching {args.sourceRepo}-cache for tag manifests...")
    spec = build_tag_spec(args.sourceRepo, args.createdWithin)
    results = run_aql_spec_search(spec, args.serverid)
    prefix = f"{args.sourceRepo}-cache/"

    # Each result path is <image>/<tag>/manifest.json or list.manifest.json
    tag_entries: List[Tuple[str, str, str]] = []
    for r in results:
        path = r.get("path", "")
        if path.startswith(prefix):
            path = path[len(prefix):]
        m = re.match(r"^(?P<image>.+)/(?P<tag>[^/]+)/(?P<file>(list\.)?manifest\.json)$", path)
        if m:
            tag_entries.append((m.group("image"), m.group("tag"), m.group("file")))

    if not tag_entries:
        log("Found 0 tag folders. Nothing to do.")
        log("=== Done ===")
        return

    log(f"Found {len(tag_entries)} tag folders. Fetching fat manifests to derive platforms...")

    cached_digests = load_cached_digests(args.sourceRepo, args.serverid)
    log(f"R1 has {len(cached_digests)} cached arch manifests across all tags.")

    out_list = f"docker-tags-{timestamp_slug()}.txt"
    multiarch_count = 0
    single_count = 0

    with open(out_list, "w") as f:
        for image, tag, tag_file in tag_entries:
            log_verbose(f"  {image}:{tag}  (from {tag_file})", args.verbose)

            if tag_file == "list.manifest.json":
                manifests = fetch_fat_manifest(image, tag, args.sourceRepo, args.serverid)
                if manifests is None:
                    log(f"  WARN: could not parse fat manifest for {image}:{tag}")
                    continue

                log_verbose(f"    Fat manifest lists {len(manifests)} entries", args.verbose)

                emitted = 0
                for m in manifests:
                    plat = m.get("platform", {})
                    arch = plat.get("architecture", "")
                    os_ = plat.get("os", "")
                    if not arch or not os_ or arch == "unknown" or os_ == "unknown":
                        continue
                    digest = m.get("digest", "")
                    digest_ref = f"{image}@{digest}"
                    if digest_ref in cached_digests:
                        f.write(f"{image}:{tag}#{os_}/{arch}\n")
                        emitted += 1

                log_verbose(f"    Kept {emitted} platform(s) matching cached digests",
                            args.verbose)

                if emitted == 0 and len(manifests) > 0:
                    log_verbose(
                        f"    No cached arch matched fat manifest — falling back to tag-only pull",
                        args.verbose,
                    )
                    f.write(f"{image}:{tag}\n")
                    single_count += 1
                else:
                    multiarch_count += emitted
            else:
                # Single-arch tag
                f.write(f"{image}:{tag}\n")
                single_count += 1
                log_verbose(f"    Single-arch tag", args.verbose)

    total = multiarch_count + single_count
    log(f"Emitted {total} pull refs: {multiarch_count} platform-scoped, "
        f"{single_count} single-arch. List: {out_list}")
    log(f"=== Done. List: {out_list} ===")


# ---------- prepopulate subcommand ----------
def parse_pull_ref(entry: str) -> Tuple[str, Optional[str]]:
    """
    Split 'image:tag#os/arch' or 'image:tag' into (ref, platform).
    Returns (ref, None) if there's no platform suffix.
    """
    if "#" in entry:
        ref, plat = entry.rsplit("#", 1)
        return ref, plat
    return entry, None


def strip_registry_prefix(ref: str, registry_host: str) -> str:
    """If ref already has the registry prefix, keep it; else prepend."""
    if ref.startswith(f"{registry_host}/"):
        return ref
    return f"{registry_host}/{ref}"


def classify_pull_error(stderr: str) -> Tuple[str, str]:
    """
    Map jf docker pull stderr to a status code and short label.
    Returns (status, label).
    """
    text = stderr.lower()
    if "manifest unknown" in text or "not found" in text or "404" in text:
        return "404", "MISS  [404]  (upstream removed / not cached)"
    if "unsupported media type" in text:
        return "FAIL", "FAIL  [---]  (unsupported media type — attestation?)"
    if "unauthorized" in text or "401" in text or "denied" in text:
        return "403", "BLOCK [403]  (auth or Curation denied)"
    if "no matching manifest" in text:
        return "FAIL", "FAIL  [---]  (no matching manifest for platform)"
    if "connection" in text or "timeout" in text:
        return "FAIL", "FAIL  [---]  (network/connection)"
    return "FAIL", "FAIL  [---]  (see report for error snippet)"


def prepopulate_one(entry: str, target_repo: str, registry_host: str, serverid: str,
                    keep_local: bool, dry_run: bool, verbose: bool,
                    writer: ReportWriter) -> None:
    ref, platform = parse_pull_ref(entry)
    full_ref = strip_registry_prefix(f"{target_repo}/{ref}", registry_host)

    cmd = ["jf", "docker", "pull", full_ref, f"--server-id={serverid}"]
    if platform:
        cmd.insert(3, f"--platform={platform}")

    if dry_run:
        log(f"  DRY   {' '.join(cmd)}")
        writer.row({"image_ref": entry, "status": "DRY"})
        return

    log_verbose(f"  RUN   {' '.join(cmd)}", verbose)
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)

    if result.returncode == 0:
        log(f"  OK    [200]  {entry}")
        writer.row({"image_ref": entry, "status": "200"})
        if not keep_local:
            # Remove from local docker to keep disk bounded
            subprocess.run(["docker", "rmi", full_ref],
                           capture_output=True, check=False)
    else:
        status, label = classify_pull_error(result.stderr)
        log(f"  {label}  {entry}")
        if verbose and result.stderr:
            snippet = result.stderr.strip().splitlines()[-1][:120] if result.stderr.strip() else ""
            log(f"         {snippet}")
        writer.row({"image_ref": entry, "status": status})


def derive_registry_host(jf_url: str) -> str:
    """
    From 'https://psblr.jfrog.io/artifactory' derive 'psblr.jfrog.io'.
    """
    return jf_url.split("://", 1)[-1].split("/", 1)[0]


def cmd_prepopulate(args: argparse.Namespace) -> None:
    if args.sourceRepo and args.fromFile:
        die("--sourceRepo and --fromFile are mutually exclusive")
    if not args.sourceRepo and not args.fromFile:
        die("one of --sourceRepo or --fromFile is required")

    log("=== Prepopulate mode (docker) ===")
    log(f"Target: {args.targetRepo}")
    log(f"Dry-run: {args.dry_run}")

    jf_cfg = get_jf_config(args.serverid)
    registry_host = args.registryHost or derive_registry_host(jf_cfg.url)
    log(f"Registry host: {registry_host}")

    if args.sourceRepo:
        log(f"Source: AQL against {args.sourceRepo}")
        # Reuse list logic by writing to a temp file then reading it
        list_ns = argparse.Namespace(
            serverid=args.serverid, sourceRepo=args.sourceRepo,
            createdWithin=args.createdWithin, verbose=args.verbose,
        )
        cmd_list(list_ns)
        import glob
        candidates = sorted(glob.glob("docker-tags-*.txt"))
        if not candidates:
            die("list step produced no output")
        input_path = candidates[-1]
        entries = read_input_list(input_path)
    else:
        log(f"Source: file {args.fromFile}")
        entries = read_input_list(args.fromFile)

    if args.dry_run:
        log("DRY RUN - no docker pulls will run")

    log(f"Pre-populating {args.targetRepo} via 'jf docker pull'...")

    report_csv = f"docker-prepop-report-{args.targetRepo}-{timestamp_slug()}.csv"

    with ReportWriter(report_csv, ["image_ref", "status"]) as writer:
        for entry in entries:
            prepopulate_one(
                entry, args.targetRepo, registry_host, args.serverid,
                keep_local=args.keep_local,
                dry_run=args.dry_run,
                verbose=args.verbose,
                writer=writer,
            )

    log(f"Complete. {len(entries)} refs processed. Report: {report_csv}")

    log("Summary:")
    import csv as _csv
    from collections import Counter
    counts: Counter = Counter()
    with open(report_csv) as f:
        for row in _csv.DictReader(f):
            counts[row["status"]] += 1
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
