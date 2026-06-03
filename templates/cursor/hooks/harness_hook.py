#!/usr/bin/env python3
"""Harness hooks for Cursor and Claude Code."""
import glob
import json
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HARNESS = os.path.join(ROOT, "harness.sh")


def emit(obj):
    print(json.dumps(obj))
    raise SystemExit(0)


def run_harness(*args):
    if not os.path.isfile(HARNESS) or not os.access(HARNESS, os.X_OK):
        return ""
    proc = subprocess.run([HARNESS, *args], cwd=ROOT, capture_output=True, text=True)
    return (proc.stdout or "").strip()


def session_index():
    ctx = run_harness("start")
    return (
        "## Harness session index (auto-injected)\n\n"
        + ctx
        + "\n\nRequired: before working on a topic run `./harness.sh recall \"<topic>\"`. "
        "On test/lint failures run `./harness.sh learn` immediately — do not re-derive."
    )


def session_start(fmt):
    text = session_index()
    if fmt == "claude":
        emit({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": text}})
    emit({"additional_context": text})


def stop_hook(fmt):
    raw = sys.stdin.read()
    try:
        data = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        data = {}
    if data.get("stop_hook_active"):
        emit({})
    run_harness("reflect")
    pending = glob.glob(os.path.join(ROOT, ".harness", "proposals", "*.md"))
    if pending and fmt == "cursor":
        emit({"followup_message": f"Harness: {len(pending)} proposal(s) ready — run ./harness.sh review"})
    emit({})


def post_shell():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        emit({})
    if data.get("tool_name") not in ("Shell", "Bash"):
        emit({})
    try:
        out = json.loads(data.get("tool_output") or "{}")
    except json.JSONDecodeError:
        emit({})
    exit_code = out.get("exitCode", out.get("exit_code", 0))
    if exit_code == 0:
        emit({})
    cmd = (data.get("tool_input") or {}).get("command", "")
    run_harness("note", f"shell failure: {cmd}")
    emit({
        "additional_context": (
            f"HARNESS: shell command failed (`{cmd}`). "
            "Before retrying, run: ./harness.sh learn --title \"...\" --fix \"...\" "
            f'--evidence "{cmd}"'
        )
    })


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    fmt = sys.argv[2] if len(sys.argv) > 2 else "cursor"
    if cmd == "session-start":
        session_start(fmt)
    if cmd == "stop":
        stop_hook(fmt)
    if cmd == "post-shell":
        post_shell()
    emit({})


if __name__ == "__main__":
    main()
