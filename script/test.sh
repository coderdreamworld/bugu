#!/usr/bin/env bash
# Runs the Bugu unit tests. XCTest ships with Xcode, not the bare Command Line
# Tools, so point DEVELOPER_DIR at a full Xcode if the active toolchain lacks it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

"$ROOT_DIR/script/test_activity.sh"
"$ROOT_DIR/script/test_magpie.sh"
python3 -m unittest discover -s Tests -p 'test_legacy_hooks.py' -q

if ! xcrun --find xctest >/dev/null 2>&1; then
  if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  else
    echo "XCTest unavailable without full Xcode; portable behavior tests passed."
    exit 0
  fi
fi

exec swift test "$@"
