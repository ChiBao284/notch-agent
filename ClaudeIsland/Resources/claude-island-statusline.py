#!/usr/bin/env python3
"""
Claude Island status line hook
- Forwards plan usage limits (5-hour / weekly) and context window usage to
  ClaudeIsland.app via Unix socket
- Prints a compact usage summary for Claude Code's own status line
"""
import json
import socket
import sys

SOCKET_PATH = "/tmp/claude-island.sock"


def send_event(state):
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(1)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state).encode())
        sock.close()
    except (socket.error, OSError):
        pass


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    session_id = data.get("session_id", "unknown")
    cwd = data.get("cwd", "")
    rate_limits = data.get("rate_limits")
    context_window = data.get("context_window")
    model_display_name = (data.get("model") or {}).get("display_name")
    model_id = (data.get("model") or {}).get("id")
    effort_level = (data.get("effort") or {}).get("level")

    if rate_limits or context_window:
        send_event({
            "session_id": session_id,
            "cwd": cwd,
            "event": "StatusLine",
            "status": "rate_limits",
            "rate_limits": rate_limits,
            "context_window": context_window,
            "model_display_name": model_display_name,
            "model_id": model_id,
            "effort_level": effort_level,
        })

    five_hour = (rate_limits or {}).get("five_hour") or {}
    seven_day = (rate_limits or {}).get("seven_day") or {}

    parts = []
    if five_hour.get("used_percentage") is not None:
        parts.append(f"5h {round(five_hour['used_percentage'])}%")
    if seven_day.get("used_percentage") is not None:
        parts.append(f"7d {round(seven_day['used_percentage'])}%")

    print(" · ".join(parts))


if __name__ == "__main__":
    main()
