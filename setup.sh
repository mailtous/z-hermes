#!/usr/bin/env bash
set -e

cd "$(dirname "$0")"

rm -rf .venv
python3 -m venv .venv
source .venv/bin/activate

pip install --upgrade pip
pip install -r requirements.txt

echo ""
echo "Done. To start:"
echo "  source .venv/bin/activate"
echo "  python cli.py"
