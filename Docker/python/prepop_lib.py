"""
prepop_lib.py — shared utilities for the prepopulate-r2 Python scripts.

Common functionality across:
  - prepopulate-r2-maven.py
  - check-upstream-maven.py
  - prepopulate-r2-docker.py
  - check-upstream-docker.py

Requires:  Python 3.8+, jf CLI on PATH, `requests` library (pip install requests)
"""

import base64
import csv
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional, Tuple

try:
    import requests
except ImportError:
    sys.stderr.write(
        "ERROR: the 'requests' library is required.\n"
        "       Install with: pip install requests\n"
    )
    sys.exit(1)


# ---------- Logging ----------
def log(msg: str) -> None:
    """Timestamped log to stdout, matching the bash scripts' format."""
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def log_verbose(msg: str, verbose: bool) -> None:
    if verbose:
        log(msg)


def die(msg: str, exit_code: int = 1) -> None:
    """Log an error and exit."""
    log(f"ERROR: {msg}")
    sys.exit(exit_code)


# ---------- Duration parsing ----------
_DURATION_RE = re.compile(r"^(\d+)(d|w|mo|y)$")


def parse_duration_to_cutoff(dur: str) -> str:
    """Convert '1y' / '6mo' / '30d' / '2w' into an ISO-8601 UTC cutoff timestamp."""
    m = _DURATION_RE.match(dur)
    if not m:
        die(f"unknown duration format '{dur}'. Use e.g. 1d, 1w, 6mo, 1y.")
    n = int(m.group(1))
    unit = m.group(2)
    days = {"d": n, "w": n * 7, "mo": n * 30, "y": n * 365}[unit]
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    return cutoff.strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------- jf CLI wrappers ----------
def run_jf(args: List[str], check: bool = True, capture: bool = True,
           input_data: Optional[str] = None, quiet_stderr: bool = True) -> Tuple[int, str, str]:
    """
    Invoke `jf` with the given args. Returns (returncode, stdout, stderr).

    check=True raises on non-zero return; check=False lets the caller inspect.
    quiet_stderr=True routes stderr to DEVNULL (useful for probes like `jf c show`).
    """
    cmd = ["jf"] + args
    stdout_dest = subprocess.PIPE if capture else None
    stderr_dest = subprocess.DEVNULL if quiet_stderr else subprocess.PIPE
    try:
        result = subprocess.run(
            cmd,
            input=input_data,
            stdout=stdout_dest,
            stderr=stderr_dest,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        die("jf CLI not found on PATH. Install JFrog CLI first.")
    if check and result.returncode != 0:
        stderr = result.stderr or ""
        die(f"jf command failed: {' '.join(cmd)}\n{stderr}")
    return result.returncode, (result.stdout or ""), (result.stderr or "")


def verify_serverid(serverid: str) -> None:
    """Fail fast if the given jf server ID is not configured."""
    rc, _, _ = run_jf(["c", "show", serverid], check=False)
    if rc != 0:
        die(f"server ID '{serverid}' not configured. Run 'jf c add' first.")


@dataclass
class JFConfig:
    """Decoded server config from `jf c export`."""
    url: str
    token: str = ""
    user: str = ""
    password: str = ""

    @property
    def auth_headers(self) -> Dict[str, str]:
        """Return headers for Bearer-token auth if a token is present."""
        if self.token:
            return {"Authorization": f"Bearer {self.token}"}
        return {}

    @property
    def basic_auth(self) -> Optional[Tuple[str, str]]:
        if self.user and self.password:
            return (self.user, self.password)
        return None


def get_jf_config(serverid: str) -> JFConfig:
    """
    Export the given serverid's config, decode the base64, and parse JSON.
    URL is normalized to end in /artifactory.
    """
    rc, raw_b64, _ = run_jf(["c", "export", serverid], check=False)
    if rc != 0 or not raw_b64.strip():
        die(f"could not export server config for '{serverid}'")
    try:
        raw_json = base64.b64decode(raw_b64.strip()).decode("utf-8")
        data = json.loads(raw_json)
    except Exception as e:
        die(f"could not decode server config: {e}")
    url = (data.get("url") or data.get("artifactoryUrl") or "").rstrip("/")
    if not url:
        die("could not parse artifactory URL from server config")
    if not url.endswith("/artifactory"):
        url = url + "/artifactory"
    token = data.get("accessToken") or ""
    user = data.get("user") or ""
    password = data.get("password") or ""
    if not token and not (user and password):
        die("no credentials found in server config (need accessToken or user+password)")
    return JFConfig(url=url, token=token, user=user, password=password)


# ---------- AQL search ----------
def run_aql_spec_search(spec: Dict[str, Any], serverid: str) -> List[Dict[str, Any]]:
    """
    Run `jf rt s --spec=<file>` with the given spec dict; return parsed JSON results.
    The bash scripts use this pattern rather than raw AQL POST because the CLI
    handles pagination and auth for us.
    """
    import tempfile
    spec_json = json.dumps(spec)
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        f.write(spec_json)
        spec_path = f.name
    try:
        rc, out, err = run_jf(
            ["rt", "s", f"--spec={spec_path}", f"--server-id={serverid}"],
            check=True, quiet_stderr=False,
        )
        # jf rt s prints [🔵Info] lines to stderr; stdout is the JSON array
        try:
            return json.loads(out) if out.strip() else []
        except json.JSONDecodeError as e:
            die(f"could not parse jf rt s output: {e}\nRaw: {out[:500]}")
    finally:
        try:
            os.unlink(spec_path)
        except OSError:
            pass


def run_aql_raw(query: str, serverid: str) -> Dict[str, Any]:
    """
    POST raw AQL to /api/search/aql via jf rt curl. Returns parsed JSON response.
    Used when we need shapes that jf rt s doesn't natively support.
    """
    rc, out, _ = run_jf(
        [
            "rt", "curl", "-X", "POST", "/api/search/aql",
            f"--server-id={serverid}",
            "-H", "Content-Type: text/plain",
            "--data-binary", query,
        ],
        check=True,
    )
    if not out.strip():
        return {"results": []}
    try:
        return json.loads(out)
    except json.JSONDecodeError as e:
        die(f"could not parse AQL response: {e}\nRaw: {out[:500]}")


# ---------- HTTP HEAD with timing ----------
@dataclass
class HeadResult:
    """Result of a single HEAD request."""
    status: str                            # "200", "404", "000", etc.
    error: str = ""                        # curl-style error message
    timing_detail: str = ""                # "dns=X tls=Y ttfb=Z total=T" (verbose only)
    headers: Dict[str, str] = field(default_factory=dict)


def head_with_timing(url: str,
                     headers: Optional[Dict[str, str]] = None,
                     auth: Optional[Tuple[str, str]] = None,
                     timeout: float = 10.0,
                     verbose: bool = False,
                     follow_redirects: bool = True,
                     session: Optional[requests.Session] = None) -> HeadResult:
    """
    Perform HTTP HEAD with per-phase timing (mirrors the bash scripts' curl -w output).

    Returns a HeadResult with:
      - status: string HTTP code, or "000" on network error
      - error: brief error description if the request failed at the network layer
      - timing_detail: 'dns=X tls=Y ttfb=Z total=T' if verbose, else empty
      - headers: response headers dict
    """
    s = session or requests.Session()
    result = HeadResult(status="000")

    t_start = time.perf_counter()
    try:
        resp = s.head(
            url,
            headers=headers or {},
            auth=auth,
            timeout=timeout,
            allow_redirects=follow_redirects,
        )
        t_total = time.perf_counter() - t_start
        result.status = str(resp.status_code)
        result.headers = dict(resp.headers)

        if verbose:
            # requests doesn't expose per-phase timers; report best-effort total
            # and the elapsed field (server-side + network)
            elapsed_s = resp.elapsed.total_seconds()
            result.timing_detail = f"elapsed={elapsed_s:.3f} total={t_total:.3f}"
    except requests.exceptions.ConnectTimeout:
        result.error = "connect timeout"
    except requests.exceptions.ReadTimeout:
        result.error = "read timeout"
    except requests.exceptions.SSLError as e:
        result.error = f"SSL error: {str(e)[:80]}"
    except requests.exceptions.ConnectionError as e:
        result.error = f"connection error: {str(e)[:80]}"
    except requests.exceptions.RequestException as e:
        result.error = f"request error: {str(e)[:80]}"
    return result


# ---------- Report writer ----------
class ReportWriter:
    """
    Append-mode CSV writer that flushes per row (so a Ctrl-C leaves a valid file).
    Usage:
        with ReportWriter('report.csv', ['coord', 'status']) as w:
            w.row({'coord': 'a:b:1', 'status': '200'})
    """
    def __init__(self, path: str, columns: List[str]):
        self.path = path
        self.columns = columns
        self._fh = None
        self._writer = None

    def __enter__(self):
        self._fh = open(self.path, "w", newline="")
        self._writer = csv.DictWriter(self._fh, fieldnames=self.columns)
        self._writer.writeheader()
        self._fh.flush()
        return self

    def row(self, values: Dict[str, str]) -> None:
        self._writer.writerow(values)
        self._fh.flush()

    def __exit__(self, exc_type, exc_val, exc_tb):
        if self._fh:
            self._fh.close()


def print_status_summary(csv_path: str, status_col: str = "status") -> Dict[str, int]:
    """
    Read a report CSV and print + return counts by status column.
    """
    counts: Dict[str, int] = {}
    with open(csv_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            s = row.get(status_col, "?")
            counts[s] = counts.get(s, 0) + 1
    log("Summary:")
    for status in sorted(counts):
        log(f"  {status:<8} : {counts[status]}")
    return counts


# ---------- Input file reader ----------
def read_input_list(path: str) -> List[str]:
    """
    Read a list file with the same semantics as the bash scripts:
      - one entry per line
      - blank lines and lines starting with # are skipped
      - trailing \\r stripped (Windows-edited files)
      - leading/trailing whitespace stripped
    """
    entries = []
    try:
        with open(path) as f:
            for raw in f:
                line = raw.rstrip("\r\n").strip()
                if not line or line.startswith("#"):
                    continue
                entries.append(line)
    except FileNotFoundError:
        die(f"cannot read {path}")
    return entries


# ---------- Timestamps for output filenames ----------
def timestamp_slug() -> str:
    """YYYYMMDD-HHMMSS local time, matches the bash scripts' 'date +%Y%m%d-%H%M%S'."""
    return time.strftime("%Y%m%d-%H%M%S")