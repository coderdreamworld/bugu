#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BINARY="$(mktemp "${TMPDIR:-/tmp}/bugu-activity-test.XXXXXX")"
trap 'rm -f "$TEST_BINARY"' EXIT

swiftc -parse-as-library \
  "$ROOT_DIR/Sources/Bugu/ActivityMonitor.swift" \
  "$ROOT_DIR/Sources/Bugu/OpenCodeActivity.swift" \
  "$ROOT_DIR/Tests/ActivityMonitorHarness.swift" \
  -o "$TEST_BINARY"
"$TEST_BINARY"
