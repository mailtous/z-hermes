#!/usr/bin/env bash
set -e

cd "$(dirname "$0")"

echo "==== start mini-hermes ===="
echo "  source .venv/bin/activate"
echo "  python cli.py"

python cli.py



