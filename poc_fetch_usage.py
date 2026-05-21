#!/usr/bin/env python3
"""POC CLI: print the Claude.ai subscription usage JSON to stdout.

The data pipeline lives in `claude_usage.py`; this file is just a thin
CLI wrapper that emits progress to stderr and the response to stdout.

The first invocation triggers a macOS Keychain prompt:
  "python wants to access 'Claude Safe Storage'"
Click "Always Allow" to suppress it on future runs.
"""
from __future__ import annotations

import json
import sys

from claude_usage import UsageError, fetch_usage, read_session_cookies


def step(n: int, total: int, msg: str) -> None:
    print(f"[{n}/{total}] {msg}", file=sys.stderr)


def main() -> None:
    try:
        step(1, 3, "Reading Keychain + decrypting cookies ...")
        cookies = read_session_cookies()
        org = cookies["lastActiveOrg"]
        print(f"      → orgUUID: {org}", file=sys.stderr)
        print(f"      → sessionKey len: {len(cookies['sessionKey'])}", file=sys.stderr)
        print(f"      → cf_clearance len: {len(cookies['cf_clearance'])}", file=sys.stderr)

        step(2, 3, f"GET /api/organizations/{org}/usage ...")
        data = fetch_usage(cookies)

        step(3, 3, "Done. Usage payload follows on stdout.")
        print(json.dumps(data, indent=2, ensure_ascii=False))
    except UsageError as e:
        sys.exit(str(e))


if __name__ == "__main__":
    main()
