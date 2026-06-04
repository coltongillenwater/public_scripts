#!/usr/bin/env python3

##########################################################
# Written by Colton Gillenwater
# Created on - 6/2/2026
##########################################################
# Script information
# Validates the reachability of URLs listed in column A of 
# a CSV under a labeled network condition
# (e.g. netskope / nordlayer / bare) and writes a set of
# per-label result columns back to the same CSV. Each run
# preserves columns from prior runs so the final file is a
# wide side-by-side comparison.
#
# For each URL, the script records: DNS resolution result,
# overall curl status, HTTP status code, a bucketed
# failure category, the final URL after redirects, and a
# block-page heuristic match. Egress IP and run metadata
# are appended to a sidecar log file for later audit.
#
# Intended for ad-hoc reachability validation across the
# a corporate network, in this case, comparing results from
# Netskope, Nordlayer, and a raw, unfiltered connection.
##########################################################

import argparse
import csv
import os
import socket
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

########################################################################################
######################### CONFIGURATION ################################################
########################################################################################

# Input/output CSV. Column A holds URLs; all other columns are preserved across runs.
# Replace with the full path to your CSV, e.g. /Users/you/Downloads/url_reachability.csv
CSV_PATH = Path("<path to local CSV here>")

# Sidecar log (same directory as CSV). Rename in with_name() if you change the CSV basename.
RUN_LOG_PATH = CSV_PATH.with_name("url_reachability_runs.log")

# Per-request timeouts (seconds). connect-timeout fails fast on dead hosts;
# max-time caps long-hanging responses so a single bad URL cannot stall the run.
CONNECT_TIMEOUT = 10
MAX_TIME = 20

# Timeout for the standalone DNS resolution check, in seconds.
DNS_TIMEOUT = 5

# Number of URLs to process in parallel. Conservative default to avoid hammering
# the corporate proxy or tripping IDS thresholds. Bump up if runtime is too slow.
MAX_WORKERS = 10

# Maximum number of body bytes to read for block-page detection. 8 KB is enough
# to catch the marker text on every Netskope / Nordlayer block page seen so far.
BLOCK_PAGE_SCAN_BYTES = 8192

# Block-page heuristics. Ordered from most specific to least specific; first match wins.
# Each entry is (lowercased substring, label written to the result column).
BLOCK_PAGE_PATTERNS = [
    ("netskope",                          "netskope_block"),
    ("nordlayer",                         "nordlayer_block"),
    ("blocked by your administrator",     "admin_block"),
    ("your administrator has restricted", "admin_block"),
    ("site has been categorized",         "category_block"),
    ("web filter",                        "web_filter"),
    ("access to this website is restricted", "restricted_site"),
    ("this page has been blocked",        "blocked_page"),
]

# Map curl exit codes to a short failure category. Anything not in the map
# falls back to "other (exit N)" so we keep visibility into unusual failures.
CURL_EXIT_CATEGORIES = {
    3:  "url_malformed",
    5:  "proxy_dns_failure",
    6:  "dns_failure",
    7:  "connection_refused",
    28: "timeout",
    35: "tls_error",
    51: "tls_error",
    52: "empty_reply",
    53: "tls_error",
    54: "tls_error",
    56: "receive_error",
    58: "tls_error",
    59: "tls_error",
    60: "tls_error",
    77: "tls_error",
    91: "tls_error",
}

# Column suffixes appended for each labelled run. Listed in the order they
# should appear in the CSV when first introduced for a label.
RESULT_SUFFIXES = [
    "dns",
    "status",
    "http_code",
    "failure_category",
    "final_url",
    "block_page",
]

# Header label of the first (URL) column. Preserved if the file already has it.
URL_HEADER_DEFAULT = "PAT URLs"

########################################################################################
######################### HELPER FUNCTIONS #############################################
########################################################################################

def get_egress_ip():
    """
    Return the apparent public egress IP by curling an echo service.

    Used as a pre-flight sanity check so the operator can confirm which
    network condition is actually in effect before launching a long run.

    Returns:
        str: The egress IP as a string, or "(unknown)" if the lookup failed.
    """
    try:
        result = subprocess.run(
            ["curl", "-sS", "--max-time", "5", "https://ifconfig.io"],
            capture_output=True, text=True, timeout=10,
        )
        ip = (result.stdout or "").strip()
        return ip or "(unknown)"
    except Exception:
        return "(unknown)"


def check_dns(url):
    """
    Resolve the hostname portion of a URL via the system resolver.

    Skips the lookup entirely when the hostname is already a literal IPv4
    address, since DNS is not in the path for those requests.

    Args:
        url (str): The full URL whose hostname should be resolved.

    Returns:
        str: "resolved", "n/a (ip)", "invalid_url", or "failed: <reason>".
    """
    try:
        parsed = urlparse(url)
    except Exception as exc:
        return f"failed: parse error ({exc})"

    hostname = parsed.hostname
    if not hostname:
        return "invalid_url"

    # Treat raw IPv4 literals as not needing DNS
    try:
        socket.inet_aton(hostname)
        return "n/a (ip)"
    except OSError:
        pass

    try:
        socket.setdefaulttimeout(DNS_TIMEOUT)
        socket.gethostbyname(hostname)
        return "resolved"
    except socket.gaierror as exc:
        return f"failed: {exc.strerror or exc}"
    except socket.timeout:
        return "failed: dns timeout"
    except Exception as exc:
        return f"failed: {exc}"
    finally:
        socket.setdefaulttimeout(None)


def detect_block_page(body_bytes):
    """
    Scan a small slice of a response body for known block-page markers.

    Patterns are checked in BLOCK_PAGE_PATTERNS order so vendor-specific
    matches (Netskope, Nordlayer) win over generic admin-block phrasing.

    Args:
        body_bytes (bytes): Raw body bytes, typically up to BLOCK_PAGE_SCAN_BYTES.

    Returns:
        str: The matched pattern label, or "" if no pattern matched.
    """
    if not body_bytes:
        return ""
    try:
        text = body_bytes.decode("utf-8", errors="replace").lower()
    except Exception:
        return ""
    for needle, label in BLOCK_PAGE_PATTERNS:
        if needle in text:
            return label
    return ""


def categorize_curl_failure(exit_code, stderr):
    """
    Map a non-zero curl exit code to a short failure category string.

    Args:
        exit_code (int): The curl process exit status.
        stderr (str): Stderr captured from the curl invocation (currently
            unused, retained so future logic can pivot on error text).

    Returns:
        str: A short category like "dns_failure", "timeout", "tls_error",
        or "other (exit N)" for unmapped codes.
    """
    return CURL_EXIT_CATEGORIES.get(exit_code, f"other (exit {exit_code})")


def curl_url(url):
    """
    Curl a single URL and return a dict of per-URL result fields.

    Writes the response body to a per-request tempfile so it can be scanned
    for block-page markers. Captures HTTP status and effective (post-redirect)
    URL via curl's --write-out format. Any non-zero curl exit is bucketed
    into a failure category; the tempfile is unlinked unconditionally.

    Args:
        url (str): The URL to fetch.

    Returns:
        dict: Keys "status", "http_code", "failure_category", "final_url",
        "block_page". Empty strings are used where a field does not apply.
    """
    # Body is written to a tempfile so curl --write-out can put status/effective
    # URL on stdout without colliding with the body stream.
    fd, body_path = tempfile.mkstemp(prefix="curlbody_", suffix=".tmp")
    os.close(fd)

    out = {
        "status": "",
        "http_code": "",
        "failure_category": "",
        "final_url": "",
        "block_page": "",
    }

    try:
        try:
            result = subprocess.run(
                [
                    "curl",
                    "-sS",
                    "-L",
                    "-o", body_path,
                    "-w", "%{http_code}\t%{url_effective}",
                    "--connect-timeout", str(CONNECT_TIMEOUT),
                    "--max-time", str(MAX_TIME),
                    url,
                ],
                capture_output=True,
                text=True,
                timeout=MAX_TIME + 5,
            )
        except subprocess.TimeoutExpired:
            out["status"] = "Failed"
            out["failure_category"] = "subprocess_timeout"
            return out
        except Exception as exc:
            out["status"] = "Failed"
            out["failure_category"] = f"exec_error: {exc}"
            return out

        # Even on non-zero exits, curl prints the format string with whatever
        # values it has (often http_code=000 and effective_url=the input URL).
        stdout = result.stdout or ""
        parts = stdout.split("\t", 1)
        if len(parts) == 2:
            http_code, final_url = parts
            out["http_code"] = http_code.strip()
            out["final_url"] = final_url.strip()

        if result.returncode == 0:
            out["status"] = "Success"
        else:
            out["status"] = "Failed"
            out["failure_category"] = categorize_curl_failure(
                result.returncode, result.stderr or ""
            )

        # Read body slice for block-page detection regardless of exit status,
        # since some block pages still return 200 with the marker text inside.
        try:
            with open(body_path, "rb") as fh:
                body_snippet = fh.read(BLOCK_PAGE_SCAN_BYTES)
            out["block_page"] = detect_block_page(body_snippet)
        except FileNotFoundError:
            pass
        except Exception:
            # Best-effort block-page detection; never let it fail the URL check
            pass

        return out
    finally:
        try:
            os.unlink(body_path)
        except FileNotFoundError:
            pass
        except Exception:
            pass


def process_url(url):
    """
    Run the DNS check and the curl check for a single URL.

    Args:
        url (str): The URL to evaluate.

    Returns:
        dict: A flat dict of all per-label fields (without label prefix).
    """
    dns_result = check_dns(url)
    curl_result = curl_url(url)
    return {
        "dns": dns_result,
        "status": curl_result["status"],
        "http_code": curl_result["http_code"],
        "failure_category": curl_result["failure_category"],
        "final_url": curl_result["final_url"],
        "block_page": curl_result["block_page"],
    }


def read_csv_rows(path):
    """
    Read the CSV into a header list and a list of dict-rows keyed by header.

    Uses utf-8-sig to transparently strip any BOM on the source file. Rows
    with an empty first column are dropped.

    Args:
        path (Path): Path to the CSV.

    Returns:
        tuple: (fieldnames_list, list_of_dict_rows)
    """
    with path.open(newline="", encoding="utf-8-sig") as fh:
        reader = csv.reader(fh)
        rows = list(reader)

    if not rows:
        return [URL_HEADER_DEFAULT], []

    header = rows[0]
    if not header:
        header = [URL_HEADER_DEFAULT]

    # Pad the header if any data row is wider than the header
    max_cols = max((len(r) for r in rows), default=len(header))
    while len(header) < max_cols:
        header.append(f"col_{len(header) + 1}")

    dict_rows = []
    for raw in rows[1:]:
        if not raw or not (raw[0] or "").strip():
            continue
        padded = raw + [""] * (len(header) - len(raw))
        dict_rows.append({header[i]: padded[i] for i in range(len(header))})

    return header, dict_rows


def write_csv_rows(path, fieldnames, dict_rows):
    """
    Write the CSV back out with the given header order and rows.

    Args:
        path (Path): Destination path (overwrites in place).
        fieldnames (list): Ordered list of column names.
        dict_rows (list): List of dict rows. Missing keys are written as empty.
    """
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for row in dict_rows:
            writer.writerow({fn: row.get(fn, "") for fn in fieldnames})


def ensure_label_columns(fieldnames, label):
    """
    Make sure the six per-label result columns exist in fieldnames.

    Columns for this label are inserted contiguously, at the end of the
    header if not already present, so the CSV stays grouped by label.

    Args:
        fieldnames (list): Current ordered list of column names (mutated).
        label (str): Run label whose columns should be guaranteed to exist.

    Returns:
        list: The (possibly extended) fieldnames list.
    """
    for suffix in RESULT_SUFFIXES:
        col = f"{label}_{suffix}"
        if col not in fieldnames:
            fieldnames.append(col)
    return fieldnames


def append_run_log(label, egress_ip, total, success, failed, duration_s):
    """
    Append a one-line run summary to the sidecar log file.

    Args:
        label (str): The label used for this run.
        egress_ip (str): Egress IP detected at the start of the run.
        total (int): Total URLs processed.
        success (int): URLs whose curl returned exit 0.
        failed (int): URLs whose curl returned non-zero.
        duration_s (float): Wall-clock seconds for the run.
    """
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = (
        f"{ts}\tlabel={label}\tegress_ip={egress_ip}"
        f"\ttotal={total}\tsuccess={success}\tfailed={failed}"
        f"\tduration_s={duration_s:.1f}\n"
    )
    with RUN_LOG_PATH.open("a", encoding="utf-8") as fh:
        fh.write(line)


def confirm_or_exit(label, egress_ip, no_confirm):
    """
    Print the run's network context and ask the operator to confirm.

    Skipped entirely if --no-confirm was passed. The point of the prompt is
    to prevent the very common mistake of running with the wrong label
    (e.g. --label bare while Netskope is still active).

    Args:
        label (str): The label about to be written.
        egress_ip (str): The detected egress IP.
        no_confirm (bool): If True, skip the interactive prompt.
    """
    print(f"[INFO] Run label:   {label}")
    print(f"[INFO] Egress IP:   {egress_ip}")
    print(f"[INFO] CSV target:  {CSV_PATH}")
    if no_confirm:
        return
    try:
        answer = input("Proceed with this run? [y/N]: ").strip().lower()
    except EOFError:
        answer = ""
    if answer not in ("y", "yes"):
        print("[INFO] Aborted by operator.")
        sys.exit(0)


########################################################################################
######################### MAIN #########################################################
########################################################################################

def main():
    parser = argparse.ArgumentParser(
        description="Check PAT URL reachability under a labelled network condition."
    )
    parser.add_argument(
        "--label",
        required=True,
        help="Network condition label, e.g. 'netskope', 'nordlayer', 'bare'.",
    )
    parser.add_argument(
        "--no-confirm",
        action="store_true",
        help="Skip the egress-IP confirmation prompt.",
    )
    args = parser.parse_args()

    label = args.label.strip()
    if not label or not all(c.isalnum() or c in ("_", "-") for c in label):
        print("[ERROR] --label must be alphanumeric, '_' or '-' only.", file=sys.stderr)
        sys.exit(1)

    if not CSV_PATH.exists():
        print(f"[ERROR] CSV not found: {CSV_PATH}", file=sys.stderr)
        sys.exit(1)

    egress_ip = get_egress_ip()
    confirm_or_exit(label, egress_ip, args.no_confirm)

    fieldnames, dict_rows = read_csv_rows(CSV_PATH)
    if not dict_rows:
        print("[ERROR] No URL rows found in CSV.", file=sys.stderr)
        sys.exit(1)

    url_col = fieldnames[0]
    fieldnames = ensure_label_columns(fieldnames, label)

    total = len(dict_rows)
    print(f"[INFO] Checking {total} URLs with {MAX_WORKERS} concurrent workers...")

    urls = [row[url_col].strip() for row in dict_rows]

    # Preserve input order by mapping future -> row index, then writing the
    # six per-label columns onto the corresponding dict row when each finishes.
    started = datetime.now()
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        future_to_idx = {pool.submit(process_url, url): idx for idx, url in enumerate(urls)}
        for n, future in enumerate(as_completed(future_to_idx), start=1):
            idx = future_to_idx[future]
            result = future.result()
            row = dict_rows[idx]
            for suffix in RESULT_SUFFIXES:
                row[f"{label}_{suffix}"] = result.get(suffix, "")
            # Progress heartbeat every 100 completions and at the end
            if n % 100 == 0 or n == total:
                print(f"[INFO] {n}/{total} complete")

    duration_s = (datetime.now() - started).total_seconds()

    write_csv_rows(CSV_PATH, fieldnames, dict_rows)

    success_count = sum(
        1 for row in dict_rows if row.get(f"{label}_status") == "Success"
    )
    failed_count = total - success_count
    append_run_log(label, egress_ip, total, success_count, failed_count, duration_s)

    print(
        f"[INFO] Done in {duration_s:.1f}s. {success_count}/{total} succeeded. "
        f"Results in column prefix '{label}_'. Audit log: {RUN_LOG_PATH}"
    )


if __name__ == "__main__":
    main()

exit(0)
