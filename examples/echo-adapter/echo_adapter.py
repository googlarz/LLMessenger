#!/usr/bin/env python3
"""
LLMessenger echo adapter — minimal Protocol v1 reference implementation.

Usage:
  chmod +x echo_adapter.py
  Copy manifest.json.example to ~/.config/llmessenger/adapters/echo/manifest.json
  Update "binary" to the absolute path of this file.
"""
import sys
import json


def respond(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def handle(req):
    method = req.get("method")

    if method == "hello":
        respond({"v": 1, "ok": True})

    elif method == "health":
        respond({"v": 1, "result": {"status": "ok", "reason": None}})

    elif method == "fetchMessages":
        respond({"v": 1, "result": {"messages": []}})

    elif method == "fetchConversations":
        respond({"v": 1, "result": {"conversations": []}})

    elif method == "fetchContacts":
        respond({"v": 1, "result": {"contacts": []}})

    elif method == "sendMessage":
        respond({"v": 1, "result": {"ok": True}})

    elif method == "markRead":
        respond({"v": 1, "result": {"ok": True}})

    else:
        respond({"v": 1, "error": f"unknown method: {method!r}", "code": 1})


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as exc:
            respond({"v": 1, "error": f"invalid JSON: {exc}", "code": 2})
            continue
        handle(req)


if __name__ == "__main__":
    main()
