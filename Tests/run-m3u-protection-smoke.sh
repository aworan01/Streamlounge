#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc Models.swift Tests/M3UProtectionSmoke.swift -o "$TMP/m3u-test"
if [[ $# -gt 0 ]]; then
  "$TMP/m3u-test" "$1"
else
  "$TMP/m3u-test"
fi
