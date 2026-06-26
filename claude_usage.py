"""Library: fetch Claude.ai subscription usage by riding on the
desktop app's existing browser session.

Pipeline:
  1. read macOS Keychain entry "Claude Safe Storage"
  2. derive AES-128 key (PBKDF2-HMAC-SHA1, salt=b"saltysalt", iter=1003)
  3. copy the Cookies SQLite to /tmp (Claude.app may hold a file lock)
  4. decrypt every cookie on .claude.ai / claude.ai
  5. GET https://claude.ai/api/organizations/<lastActiveOrg>/usage,
     re-playing the full cookie jar + a Chrome-ish UA so Cloudflare's
     `cf_clearance` check passes.

Stdlib only; macOS `security` and `openssl` are used via subprocess.
Nothing is written to disk.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

COOKIE_DB = Path.home() / "Library/Application Support/Claude/Cookies"
KEYCHAIN_SERVICE = "Claude Safe Storage"
HOSTS = (".claude.ai", "claude.ai")
REQUIRED_COOKIES = ("sessionKey", "lastActiveOrg")
CLAUDE_APP = Path("/Applications/Claude.app")

GENERIC_CHROME_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/131.0.0.0 Safari/537.36"
)

DEBUG = bool(os.environ.get("CLAUDE_USAGE_DEBUG"))


def _debug(msg: str) -> None:
    if DEBUG:
        print(f"[claude_usage] {msg}", file=sys.stderr)


def _plist_read(plist: Path, key: str) -> str | None:
    # `defaults read` wants the path without the .plist suffix
    target = str(plist.with_suffix("")) if plist.suffix == ".plist" else str(plist)
    r = subprocess.run(
        ["defaults", "read", target, key],
        capture_output=True, text=True,
    )
    return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else None


def _detect_claude_app_ua() -> str:
    """Best-effort: reconstruct Claude.app's actual User-Agent.

    cf_clearance is bound to the UA Claude.app sent when it was issued, so a
    stock Chrome UA can be rejected. We try to read three pieces:
      - Claude.app version (from the bundle's Info.plist)
      - Chrome version (from the Electron framework binary via `strings`)
      - Electron version (plist or `strings` fallback)

    Chrome version is the load-bearing one; we degrade gracefully if the
    other two aren't found.
    """
    if not CLAUDE_APP.exists():
        return GENERIC_CHROME_UA
    claude_ver = _plist_read(CLAUDE_APP / "Contents/Info.plist", "CFBundleShortVersionString")
    electron_plist = (
        CLAUDE_APP / "Contents/Frameworks/Electron Framework.framework/Resources/Info.plist"
    )
    electron_ver = (
        _plist_read(electron_plist, "CFBundleShortVersionString")
        or _plist_read(electron_plist, "CFBundleVersion")
    )
    framework_bin = (
        CLAUDE_APP
        / "Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework"
    )
    chrome_ver: str | None = None
    if framework_bin.exists():
        try:
            r = subprocess.run(
                ["strings", str(framework_bin)],
                capture_output=True, text=True, timeout=10,
            )
            m = re.search(r"Chrome/(\d+\.\d+\.\d+\.\d+)", r.stdout)
            if m:
                chrome_ver = m.group(1)
            if not electron_ver:
                m2 = re.search(r"\bElectron/(\d+\.\d+\.\d+(?:\.\d+)?)\b", r.stdout)
                if m2:
                    electron_ver = m2.group(1)
        except (subprocess.TimeoutExpired, OSError):
            pass

    _debug(f"UA detect: claude={claude_ver} chrome={chrome_ver} electron={electron_ver}")
    if not chrome_ver:
        return GENERIC_CHROME_UA
    parts = ["Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
             "AppleWebKit/537.36 (KHTML, like Gecko)"]
    if claude_ver:
        parts.append(f"Claude/{claude_ver}")
    parts.append(f"Chrome/{chrome_ver}")
    if electron_ver:
        parts.append(f"Electron/{electron_ver}")
    parts.append("Safari/537.36")
    return " ".join(parts)


USER_AGENT = os.environ.get("CLAUDE_USAGE_UA") or _detect_claude_app_ua()


class UsageError(RuntimeError):
    """Anything that prevented us from fetching usage end-to-end."""


def _keychain_password() -> str:
    r = subprocess.run(
        ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        raise UsageError(
            f"keychain read failed for {KEYCHAIN_SERVICE!r}: "
            f"{r.stderr.strip() or '(no stderr)'}"
        )
    return r.stdout.strip()


def _aes_key(password: str) -> bytes:
    return hashlib.pbkdf2_hmac("sha1", password.encode(), b"saltysalt", 1003, 16)


def _load_encrypted_cookies() -> dict[str, bytes]:
    """Pull every cookie set on a claude.ai host, not just the ones we know.

    Cloudflare's bot check looks at the whole jar (cf_clearance, __cf_bm,
    _cfuvid, …); sending an incomplete set triggers a JS challenge → 403.
    """
    if not COOKIE_DB.exists():
        raise UsageError(f"cookie DB not found: {COOKIE_DB}")
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td) / "Cookies"
        shutil.copy2(COOKIE_DB, tmp)
        conn = sqlite3.connect(tmp)
        hosts_q = ",".join("?" for _ in HOSTS)
        rows = conn.execute(
            f"SELECT name, encrypted_value FROM cookies "
            f"WHERE host_key IN ({hosts_q})",
            HOSTS,
        ).fetchall()
        conn.close()
    out: dict[str, bytes] = {}
    for name, enc in rows:
        # Two rows can match (.claude.ai + claude.ai); keep the longer payload.
        if name not in out or len(enc) > len(out[name]):
            out[name] = enc
    return out


def _decrypt(encrypted: bytes, aes_key: bytes) -> str:
    prefix, payload = encrypted[:3], encrypted[3:]
    if prefix not in (b"v10", b"v11"):
        raise UsageError(f"unknown cookie prefix: {prefix!r}")
    iv_hex = "20" * 16  # 16 ASCII spaces, per Chromium convention
    r = subprocess.run(
        ["openssl", "enc", "-aes-128-cbc", "-d", "-K", aes_key.hex(), "-iv", iv_hex],
        input=payload, capture_output=True,
    )
    if r.returncode != 0:
        raise UsageError(
            f"openssl decrypt failed: {r.stderr.decode(errors='replace').strip()}"
        )
    plaintext = r.stdout
    # Chromium ≥ ~v130 prepends a 32-byte SHA256(host) hash to the plaintext
    # to bind the cookie to its origin. Detect and skip it; older binaries
    # store the raw value with no prefix.
    if len(plaintext) > 32 and any(b < 0x20 or b > 0x7e for b in plaintext[:32]):
        plaintext = plaintext[32:]
    return plaintext.decode("utf-8", errors="replace")


def read_session_cookies() -> dict[str, str]:
    """Return all decrypted claude.ai cookies, or raise UsageError."""
    password = _keychain_password()
    key = _aes_key(password)
    encrypted = _load_encrypted_cookies()
    cookies = {name: _decrypt(enc, key) for name, enc in encrypted.items()}
    missing = [c for c in REQUIRED_COOKIES if not cookies.get(c)]
    if missing:
        raise UsageError(
            f"missing required cookies {missing} — open the Claude desktop app and log in"
        )
    return cookies


def _cookie_header(cookies: dict[str, str]) -> str:
    # Send everything Cloudflare set + the Claude session, but not internal
    # markers like lastActiveOrg (it's a URL component, not an HTTP cookie
    # the API server expects).
    return "; ".join(f"{k}={v}" for k, v in cookies.items() if k != "lastActiveOrg")


def _system_proxy() -> str | None:
    """Return the macOS system HTTPS proxy as a URL, or None.

    cf_clearance is bound to the egress IP that issued it. Claude.app uses the
    macOS *system* proxy, so its cookie is tied to that proxy's IP. curl only
    honors proxy *environment variables*, not the system network settings — so
    when this script runs from a GUI launch (no proxy env vars) curl would go
    direct, land on a different IP, and Cloudflare would reject it (302/403).
    We bridge that gap by reading the system proxy and handing it to curl.
    """
    # An explicit env proxy wins; curl already honors it, so don't override.
    for var in ("HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"):
        if os.environ.get(var):
            return None
    r = subprocess.run(["scutil", "--proxy"], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    fields: dict[str, str] = {}
    for line in r.stdout.splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            fields[k.strip()] = v.strip()
    if fields.get("HTTPSEnable") == "1" and fields.get("HTTPSProxy"):
        host = fields["HTTPSProxy"]
        port = fields.get("HTTPSPort", "")
        return f"http://{host}:{port}" if port else f"http://{host}"
    return None


def _curl_get(url: str, cookie_header: str) -> tuple[int, bytes]:
    """GET via system curl. urllib's TLS handshake is identifiable as Python
    and trips Cloudflare's bot check; macOS's curl uses LibreSSL + ALPN +
    HTTP/2 in a way that more closely matches a real browser."""
    with tempfile.NamedTemporaryFile(delete=False) as f:
        body_path = f.name
    try:
        cmd = [
            "curl", "-sS",
            "--max-time", "10",
            "--compressed",
            "--http2",
            "-o", body_path,
            "-w", "%{http_code}",
        ]
        proxy = _system_proxy()
        if proxy:
            _debug(f"using system proxy: {proxy}")
            cmd += ["-x", proxy]
        cmd += [
            "-H", f"User-Agent: {USER_AGENT}",
            "-H", "Accept: application/json, text/plain, */*",
            "-H", "Accept-Language: en-US,en;q=0.9",
            "-H", "Referer: https://claude.ai/",
            "-H", "Origin: https://claude.ai",
            "-H", "Sec-Fetch-Site: same-origin",
            "-H", "Sec-Fetch-Mode: cors",
            "-H", "Sec-Fetch-Dest: empty",
            "-H", f"Cookie: {cookie_header}",
            url,
        ]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if r.returncode != 0:
            raise UsageError(
                f"curl failed (rc={r.returncode}): {r.stderr.strip() or '(no stderr)'}"
            )
        try:
            status = int(r.stdout.strip())
        except ValueError:
            raise UsageError(f"unexpected curl status output: {r.stdout!r}")
        return status, Path(body_path).read_bytes()
    finally:
        try:
            os.unlink(body_path)
        except OSError:
            pass


def fetch_usage(cookies: dict[str, str] | None = None) -> dict:
    """Return the raw usage JSON, or raise UsageError.

    Pass `cookies` from a previous `read_session_cookies()` call to skip
    re-reading the keychain; otherwise this re-derives them.
    """
    if cookies is None:
        cookies = read_session_cookies()
    org_uuid = cookies["lastActiveOrg"]
    _debug(f"User-Agent: {USER_AGENT}")
    _debug(f"cookies present: {sorted(cookies.keys())}")
    _debug(f"orgUUID: {org_uuid}")
    url = f"https://claude.ai/api/organizations/{org_uuid}/usage"
    status, body = _curl_get(url, _cookie_header(cookies))
    _debug(f"HTTP {status}, body_len={len(body)}")
    if status != 200:
        snippet = body.decode("utf-8", errors="replace").strip()[:300]
        raise UsageError(f"HTTP {status}: {snippet}")
    try:
        return json.loads(body)
    except json.JSONDecodeError as e:
        raise UsageError(
            f"non-JSON response: {e}; body[:200]={body[:200].decode('utf-8', errors='replace')!r}"
        )
