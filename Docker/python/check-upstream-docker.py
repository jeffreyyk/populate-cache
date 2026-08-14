#!/usr/bin/env python3
"""
check-upstream-docker.py
------------------------------------------------------------------
Python port of check-upstream-docker.sh.

Given a list of Docker image:tag refs (from file or AQL), HEAD each
directly against the upstream Docker registry to determine whether
the image still exists.

R1's config is used only to discover the upstream URL; actual checks
bypass R1 entirely so results reflect real upstream state.

Auth flow (per Docker Registry v2 spec):
  1. HEAD with whatever auth is on hand (Bearer, Basic, or none).
  2. If 401 + Www-Authenticate: Bearer challenge, extract realm and
     service, GET a token, retry HEAD with Bearer token.
  3. Handles DockerHub public (anonymous+bearer), authenticated
     DockerHub (basic auth on token endpoint), GHCR, private
     Nexus/Harbor with basic, and pre-obtained bearer tokens.

--via-r1 alternative: route through the tenant's own Docker Registry
API endpoint, useful when a corporate proxy blocks direct upstream
access from the client machine.
"""

import argparse
import json
import re
import sys
from typing import List, Optional, Tuple

import requests

from prepop_lib import (
    JFConfig, ReportWriter,
    die, get_jf_config, log, parse_duration_to_cutoff,
    read_input_list, run_aql_spec_search, run_jf,
    timestamp_slug, verify_serverid,
)


ACCEPT_MANIFEST = (
    "application/vnd.oci.image.index.v1+json,"
    "application/vnd.docker.distribution.manifest.list.v2+json,"
    "application/vnd.docker.distribution.manifest.v2+json,"
    "application/vnd.oci.image.manifest.v1+json"
)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Check whether Docker images exist upstream.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--serverid", required=True)
    p.add_argument("--sourceRepo", required=True,
                   help="Docker remote whose upstream URL we resolve")
    p.add_argument("--fromFile", help="Read image:tag list from a file")
    p.add_argument("--createdWithin", help="AQL filter (e.g. 1y) for auto-enumerate")
    p.add_argument("--upstreamUser")
    p.add_argument("--upstreamPassword")
    p.add_argument("--upstreamAuthToken",
                   help="Pre-obtained Bearer token; overrides user/pass")
    p.add_argument("--via-r1", action="store_true", dest="via_r1",
                   help="Route through tenant's Docker API instead of upstream")
    p.add_argument("--connect-timeout", type=float, default=10.0,
                   dest="connect_timeout")
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
    # DockerHub cosmetic: normalize index.docker.io -> registry-1.docker.io
    url = url.replace("https://index.docker.io", "https://registry-1.docker.io")
    return url


def build_spec(sourceRepo: str, createdWithin: Optional[str]) -> dict:
    """Find tag folders (manifest.json / list.manifest.json), skipping sha256__ digest folders."""
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


_TAG_PATH_RE = re.compile(r"^(?P<image>.+)/(?P<tag>[^/]+)/(list\.)?manifest\.json$")


def aql_to_image_tags(results: list, source_repo: str) -> List[str]:
    """Convert AQL results to sorted unique 'image:tag' entries."""
    prefix = f"{source_repo}-cache/"
    seen = set()
    for entry in results:
        path = entry.get("path", "")
        if path.startswith(prefix):
            path = path[len(prefix):]
        m = _TAG_PATH_RE.match(path)
        if m:
            seen.add(f"{m.group('image')}:{m.group('tag')}")
    return sorted(seen)


# ---------- Bearer challenge parsing ----------
_REALM_RE = re.compile(r'realm="([^"]+)"')
_SERVICE_RE = re.compile(r'service="([^"]+)"')


def parse_bearer_challenge(www_auth: str, image: str) -> Optional[str]:
    """Parse a Www-Authenticate Bearer challenge into a token URL."""
    if "bearer" not in www_auth.lower():
        return None
    realm_m = _REALM_RE.search(www_auth)
    service_m = _SERVICE_RE.search(www_auth)
    if not realm_m:
        return None
    realm = realm_m.group(1)
    scope = f"repository:{image}:pull"
    if service_m:
        return f"{realm}?service={service_m.group(1)}&scope={scope}"
    return f"{realm}?scope={scope}"


def fetch_bearer_token(token_url: str, upstream_user: str, upstream_pass: str,
                       timeout: float, session: requests.Session) -> Optional[str]:
    auth = (upstream_user, upstream_pass) if upstream_user else None
    try:
        resp = session.get(token_url, auth=auth, timeout=timeout)
        if resp.status_code != 200:
            return None
        data = resp.json()
        return data.get("token") or data.get("access_token")
    except requests.exceptions.RequestException:
        return None
    except json.JSONDecodeError:
        return None


# ---------- Upstream check per image:tag ----------
def build_check_url(input_line: str, args: argparse.Namespace,
                    upstream_url: str, jf_cfg: JFConfig) -> Tuple[str, str, str]:
    """
    Return (url, image, tag) for the HEAD.
    Strips optional #os/arch suffix from prepopulate list output.
    """
    ref = input_line.split("#", 1)[0]
    image, tag = ref.rsplit(":", 1)
    if args.via_r1:
        url = f"{jf_cfg.url}/api/docker/{args.sourceRepo}/v2/{image}/manifests/{tag}"
    else:
        url = f"{upstream_url}/v2/{image}/manifests/{tag}"
    return url, image, tag


def check_one(input_line: str, args: argparse.Namespace, upstream_url: str,
              jf_cfg: JFConfig, session: requests.Session,
              writer: ReportWriter) -> None:
    url, image, tag = build_check_url(input_line, args, upstream_url, jf_cfg)

    # First HEAD with whatever auth we have
    if args.via_r1:
        headers = {"Accept": ACCEPT_MANIFEST, **jf_cfg.auth_headers}
        auth = jf_cfg.basic_auth
    else:
        headers = {"Accept": ACCEPT_MANIFEST}
        auth = None
        if args.upstreamAuthToken:
            headers["Authorization"] = f"Bearer {args.upstreamAuthToken}"
        elif args.upstreamUser:
            auth = (args.upstreamUser, args.upstreamPassword or "")

    status = "000"
    error = ""
    www_auth = ""
    try:
        resp = session.head(url, headers=headers, auth=auth,
                            timeout=args.connect_timeout,
                            allow_redirects=True)
        status = str(resp.status_code)
        www_auth = resp.headers.get("Www-Authenticate", "")
    except requests.exceptions.RequestException as e:
        error = str(e)[:80]

    # If 401 and not via-r1, try bearer challenge
    if status == "401" and not args.via_r1 and www_auth:
        token_url = parse_bearer_challenge(www_auth, image)
        if token_url:
            token = fetch_bearer_token(
                token_url, args.upstreamUser or "", args.upstreamPassword or "",
                args.connect_timeout, session,
            )
            if token:
                try:
                    resp = session.head(url,
                                        headers={"Accept": ACCEPT_MANIFEST,
                                                 "Authorization": f"Bearer {token}"},
                                        timeout=args.connect_timeout,
                                        allow_redirects=True)
                    status = str(resp.status_code)
                except requests.exceptions.RequestException as e:
                    error = str(e)[:80]

    ref = input_line.split("#", 1)[0]

    # 30x redirect labels (proxy interception)
    if status in ("301", "302", "307"):
        label = f"BLOCK [{status}]  {ref}  (proxy/filter redirect)"
    elif status == "200":
        label = f"OK    [200]  {ref}"
    elif status in ("401", "403"):
        via = "tenant" if args.via_r1 else "upstream"
        label = f"AUTH  [{status}]  {ref}  ({via} returned {status})"
    elif status == "404":
        label = f"MISS  [404]  {ref}  (missing from upstream)"
    elif status == "429":
        label = f"RATE  [429]  {ref}  (rate-limited)"
    elif status == "000":
        label = f"FAIL  [---]  {ref}  ({error})"
    else:
        label = f"?     [{status}]  {ref}"

    log(f"  {label}")
    writer.row({"image": image, "tag": tag, "upstream_status": status})


def main() -> None:
    args = parse_args()
    log("=== Upstream check (docker) ===")
    log(f"Source repo: {args.sourceRepo}")

    verify_serverid(args.serverid)
    jf_cfg = get_jf_config(args.serverid)

    if args.via_r1:
        upstream_url = ""
        log(f"Mode: via R1 ({jf_cfg.url}/api/docker/{args.sourceRepo}/v2/...)")
    else:
        upstream_url = get_upstream_url(args.sourceRepo, args.serverid)
        log(f"Upstream URL: {upstream_url}")
        if args.upstreamAuthToken:
            log("Auth: static Bearer token")
        elif args.upstreamUser:
            log(f"Auth: basic ({args.upstreamUser})")
        else:
            log("Auth: anonymous (bearer challenge if upstream requires)")

    # Build input list
    if args.fromFile:
        log(f"Input: file {args.fromFile}")
        entries = read_input_list(args.fromFile)
    else:
        log(f"Input: AQL against {args.sourceRepo}")
        spec = build_spec(args.sourceRepo, args.createdWithin)
        results = run_aql_spec_search(spec, args.serverid)
        entries = aql_to_image_tags(results, args.sourceRepo)
        list_path = f"check-docker-list-{timestamp_slug()}.txt"
        with open(list_path, "w") as f:
            for e in entries:
                f.write(e + "\n")
        log(f"Found {len(entries)} unique image:tag entries. List: {list_path}")

    log("Checking...")

    report_csv = f"upstream-check-docker-{args.sourceRepo}-{timestamp_slug()}.csv"
    session = requests.Session()

    with ReportWriter(report_csv, ["image", "tag", "upstream_status"]) as writer:
        for line in entries:
            check_one(line, args, upstream_url, jf_cfg, session, writer)

    log(f"Complete. {len(entries)} tags checked. Report: {report_csv}")

    # Summary and missing.txt
    import csv as _csv
    from collections import Counter
    counts: Counter = Counter()
    missing: List[str] = []
    with open(report_csv) as f:
        for row in _csv.DictReader(f):
            counts[row["upstream_status"]] += 1
            if row["upstream_status"] == "404":
                missing.append(f"{row['image']}:{row['tag']}")

    log("Summary (by status):")
    for s in sorted(counts):
        log(f"  {s:<8} : {counts[s]}")

    if missing:
        missing_txt = f"upstream-missing-docker-{args.sourceRepo}-{timestamp_slug()}.txt"
        with open(missing_txt, "w") as f:
            for m in sorted(set(missing)):
                f.write(m + "\n")
        log(f"{len(set(missing))} image(s) missing from upstream: {missing_txt}")
        log("Feed this file into the rescue-local remediation step.")
    else:
        log("No missing images detected. Nothing to remediate.")

    log("=== Done ===")


if __name__ == "__main__":
    main()
