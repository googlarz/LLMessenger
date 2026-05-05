#!/usr/bin/env python3
"""
Run once to authenticate with Telegram.
Usage: python3 auth.py --api-id API_ID --api-hash API_HASH --session-path PATH
"""
import argparse
import asyncio
from pyrogram import Client

async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--api-id",      required=True, type=int)
    parser.add_argument("--api-hash",    required=True)
    parser.add_argument("--session-path", default="telegram_session")
    args = parser.parse_args()

    async with Client(
        args.session_path,
        api_id=args.api_id,
        api_hash=args.api_hash
    ) as app:
        me = await app.get_me()
        print(f"Authenticated as {me.first_name} ({me.phone_number})")
        print(f"Session saved to: {args.session_path}.session")

if __name__ == "__main__":
    asyncio.run(main())
