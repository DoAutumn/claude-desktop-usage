#!/usr/bin/env python3
# <xbar.title>Claude Usage</xbar.title>
# <xbar.version>0.1.0</xbar.version>
# <xbar.author>claude-desktop-usage-menubar</xbar.author>
# <xbar.desc>Show your Claude.ai 5h / 7d subscription usage in the menubar.</xbar.desc>
# <xbar.dependencies>python3, openssl, security</xbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
"""SwiftBar / xbar plugin: render Claude.ai usage in the macOS menubar.

Install:
  1. Install SwiftBar (`brew install --cask swiftbar`) and pick a plugin folder
  2. Symlink this file in with a SwiftBar-style refresh suffix, e.g.:
       ln -s "$(pwd)/swiftbar_plugin.py" \\
             "$HOME/Library/Application Support/SwiftBar/Plugins/claude-usage.5m.py"
     The ".5m" tells SwiftBar to re-run every 5 minutes.
  3. `chmod +x swiftbar_plugin.py` (already done if you cloned this repo).
"""
from __future__ import annotations

import os
import sys
from datetime import datetime

# Resolve the real script directory even when SwiftBar runs us via a symlink,
# so the sibling `claude_usage` module is importable.
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))

from claude_usage import UsageError, fetch_usage  # noqa: E402


def _fmt_pct(value) -> str:
    if value is None:
        return "—"
    try:
        return f"{float(value):.0f}%"
    except (TypeError, ValueError):
        return "—"


def _fmt_reset(iso: str | None) -> str:
    if not iso:
        return "no reset scheduled"
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone()
    except ValueError:
        return iso
    now = datetime.now(dt.tzinfo)
    secs = int((dt - now).total_seconds())
    if secs <= 0:
        return f"resets {dt:%-I:%M %p}"
    h, rem = divmod(secs, 3600)
    m, _ = divmod(rem, 60)
    if h >= 24:
        d, hh = divmod(h, 24)
        return f"resets in {d}d {hh}h ({dt:%a %-I:%M %p})"
    if h:
        return f"resets in {h}h {m:02d}m ({dt:%-I:%M %p})"
    return f"resets in {m}m ({dt:%-I:%M %p})"


def _emit(line: str, **attrs) -> None:
    if attrs:
        line = line + " | " + " ".join(f"{k}={v}" for k, v in attrs.items())
    print(line)


def main() -> None:
    try:
        data = fetch_usage()
    except UsageError as e:
        _emit("⚠ Claude")
        _emit("---")
        _emit(f"Error: {e}", color="red")
        _emit("Open Claude.ai", href="https://claude.ai")
        _emit("Refresh", refresh="true")
        return

    five = data.get("five_hour") or {}
    seven = data.get("seven_day") or {}
    five_pct = _fmt_pct(five.get("utilization"))
    seven_pct = _fmt_pct(seven.get("utilization"))

    _emit(f"5h {five_pct} · 7d {seven_pct}")
    _emit("---")
    _emit(f"5-hour: {five_pct} — {_fmt_reset(five.get('resets_at'))}", font="Menlo")
    _emit(f"7-day:  {seven_pct} — {_fmt_reset(seven.get('resets_at'))}", font="Menlo")
    _emit("---")
    for key, label in (
        ("seven_day_sonnet", "Sonnet (7d)"),
        ("seven_day_opus", "Opus (7d)"),
        ("seven_day_oauth_apps", "OAuth apps (7d)"),
    ):
        bucket = data.get(key) or {}
        _emit(f"{label}: {_fmt_pct(bucket.get('utilization'))}", font="Menlo")
    _emit("---")
    _emit("Open Claude.ai", href="https://claude.ai")
    _emit("Refresh", refresh="true")
    _emit(f"Updated {datetime.now():%-I:%M %p}", color="gray", size="11")


if __name__ == "__main__":
    main()
