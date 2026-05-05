#!/bin/bash
# Builds the Telegram adapter as a standalone frozen binary using PyInstaller.
# Output: dist/telegram-adapter (no Python dependency on the end-user machine)
set -e

cd "$(dirname "$0")"

python3 -m venv .venv
.venv/bin/pip install -r requirements.txt pyinstaller
.venv/bin/pyinstaller --onefile --name telegram-adapter adapter.py

echo "Built: dist/telegram-adapter"
