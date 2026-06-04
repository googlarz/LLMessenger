#!/usr/bin/env python3
"""
Telegram adapter for LLMessenger.
Reads NDJSON from stdin, writes NDJSON to stdout.
"""
import os
import sys
import json
import asyncio
from datetime import datetime, timezone
from pyrogram import Client
from pyrogram.enums import ChatType
from pyrogram.errors import SessionPasswordNeeded

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
    cid_str = str(req["conversation_id"]).strip()
    if not cid_str.lstrip("-").isdigit():
        raise ValueError(f"Invalid conversation_id format: {cid_str!r}")
    cid = int(cid_str)
    await app.send_message(cid, req["text"])
    return {"success": True}

async def handle_auth_loop(app: Client):
    """Serve auth_* actions on a connected-but-unauthorized client, then return."""
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            print(json.dumps({"success": False, "error": f"invalid JSON: {e}"}), flush=True)
            continue

        action = req.get("action")
        try:
            if action == "auth_send_code":
                phone = req["phone"]
                sent = await app.send_code(phone)
                result = {"success": True, "phone_code_hash": sent.phone_code_hash}
            elif action == "auth_sign_in":
                phone          = req["phone"]
                phone_code_hash = req["phone_code_hash"]
                code           = req["code"]
                try:
                    await app.sign_in(phone, phone_code_hash, code)
                    result = {"success": True}
                    print(json.dumps(result), flush=True)
                    return  # session established — exit auth loop
                except SessionPasswordNeeded:
                    result = {"success": False, "needs_2fa": True}
            elif action == "auth_check_password":
                await app.check_password(req["password"])
                result = {"success": True}
                print(json.dumps(result), flush=True)
                return  # session established — exit auth loop
            else:
                result = {"success": False, "error": f"unknown auth action: {action}"}
        except Exception as e:
            result = {"success": False, "error": str(e)}

        print(json.dumps(result), flush=True)


async def command_loop(app: Client):
    """Read newline-delimited JSON requests from stdin, dispatch, write replies."""
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

    has_session = os.path.exists(f"{session_path}.session")

    if has_session:
        # Authorized path: a single context-managed Client. `async with` calls
        # start() (which connects and sets up the dispatcher). On exit it
        # disconnects and releases the SQLite handle cleanly.
        async with Client(session_path, api_id=api_id, api_hash=api_hash) as app:
            print(json.dumps({"success": True}), flush=True)
            await command_loop(app)
    else:
        # First-run / unauthorized: connect manually so stdin stays available
        # for the auth flow, then keep the SAME client connected for fetch/send.
        # We intentionally never disconnect/reconnect in this lifetime — doing
        # so leaves Pyrogram's SQLite session journal in a locked state and the
        # next open fails with "database is locked".
        app = Client(session_path, api_id=api_id, api_hash=api_hash)
        await app.connect()
        try:
            print(json.dumps({"success": True, "needs_auth": True}), flush=True)
            await handle_auth_loop(app)
            # Auth loop returned, so the user is authorized on this connection.
            # Manually initialise the dispatcher so get_dialogs() works.
            await app.initialize()
            await command_loop(app)
        finally:
            try:
                await app.terminate()
            except Exception:
                pass
            try:
                await app.disconnect()
            except Exception:
                pass

if __name__ == "__main__":
    asyncio.run(main())
