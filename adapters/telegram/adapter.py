#!/usr/bin/env python3
"""
Telegram adapter for LLMessenger.
Reads NDJSON from stdin, writes NDJSON to stdout.
"""
import sys
import json
import asyncio
from datetime import datetime, timezone
from pyrogram import Client
from pyrogram.enums import ChatType

def ts(dt) -> str:
    """Convert datetime to ISO8601 UTC string."""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.isoformat().replace("+00:00", "Z")

async def handle_fetch(app: Client, req: dict) -> dict:
    mode = req.get("mode", "count")
    limit = req.get("limit", 50)
    since = None
    if mode == "time":
        since = datetime.fromisoformat(req["since"].replace("Z", "+00:00")).replace(tzinfo=None)

    # Per-dialog fetch limit: tighter in time mode since we break on old messages anyway.
    per_dialog_limit = 50 if since else limit

    conversations = []

    async for dialog in app.get_dialogs():
        # Fast-path: skip dialogs with no activity since `since`.
        if since and dialog.top_message and dialog.top_message.date:
            top_date = dialog.top_message.date
            top_date = top_date.replace(tzinfo=None) if top_date.tzinfo else top_date
            if top_date < since:
                continue

        messages = []
        chat_id = dialog.chat.id

        async for msg in app.get_chat_history(chat_id, limit=per_dialog_limit):
            if not msg.text:
                continue
            msg_date = msg.date.replace(tzinfo=None) if msg.date.tzinfo else msg.date
            if since and msg_date < since:
                break
            sender = "Unknown"
            if msg.from_user:
                sender = msg.from_user.first_name or "Unknown"
            elif msg.sender_chat:
                sender = msg.sender_chat.title or "Unknown"
            messages.append({
                "id":        str(msg.id),
                "sender":    sender,
                "text":      msg.text,
                "timestamp": ts(msg.date)
            })

        if not messages:
            continue

        chat_type = "dm"
        if dialog.chat.type in (ChatType.GROUP, ChatType.SUPERGROUP, ChatType.CHANNEL):
            chat_type = "group"

        name = dialog.chat.title or dialog.chat.first_name or str(dialog.chat.id)
        conversations.append({
            "id":       str(chat_id),
            "name":     name,
            "type":     chat_type,
            "messages": messages
        })

    return {"conversations": conversations}

async def handle_send(app: Client, req: dict) -> dict:
    await app.send_message(int(req["conversation_id"]), req["text"])
    return {"success": True}

async def main():
    # Read init line
    init_line = sys.stdin.readline().strip()
    if not init_line:
        print(json.dumps({"success": False, "error": "no init received"}), flush=True)
        return

    try:
        init = json.loads(init_line)
    except json.JSONDecodeError as e:
        print(json.dumps({"success": False, "error": f"invalid init JSON: {e}"}), flush=True)
        return
    cfg = init.get("config", {})
    api_id       = int(cfg["api_id"])
    api_hash     = cfg["api_hash"]
    session_path = cfg.get("session_path", "telegram_session")

    async with Client(session_path, api_id=api_id, api_hash=api_hash) as app:
        print(json.dumps({"success": True}), flush=True)

        for raw_line in sys.stdin:
            line = raw_line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
                action = req.get("action")
                if action == "fetch":
                    result = await handle_fetch(app, req)
                elif action == "send":
                    result = await handle_send(app, req)
                elif action == "health":
                    result = {"status": "ok"}
                else:
                    result = {"error": f"unknown action: {action}"}
            except Exception as e:
                result = {"error": str(e)}

            print(json.dumps(result), flush=True)

if __name__ == "__main__":
    asyncio.run(main())
