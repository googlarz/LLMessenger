#!/bin/bash
# Builds the Telegram adapter as a standalone frozen binary using PyInstaller.
# Output: dist/telegram-adapter (no Python dependency on the end-user machine)
set -e

cd "$(dirname "$0")"

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt pyinstaller

pyinstaller --onefile --name telegram-adapter adapter.py

echo "Built: dist/telegram-adapter"
