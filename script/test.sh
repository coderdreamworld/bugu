#!/usr/bin/env bash
# Runs the portable Bugu behavior tests with Command Line Tools.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

"$ROOT_DIR/script/test_activity.sh"
"$ROOT_DIR/script/test_native.sh"
"$ROOT_DIR/script/test_magpie.sh"
python3 -m unittest discover -s Tests -p 'test_legacy_hooks.py' -q
