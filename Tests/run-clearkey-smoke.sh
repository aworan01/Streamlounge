#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
python3 - "$TMP/ClearKeyCore.swift" <<'PY'
from pathlib import Path
import sys
s=Path('ClearKey.swift').read_text()
start=s.index('struct ClearKeyProfile:')
end=s.index('@MainActor final class ClearKeyVault')
Path(sys.argv[1]).write_text('import Foundation\n'+s[start:end])
PY
swiftc "$TMP/ClearKeyCore.swift" Tests/ClearKeySmoke.swift -o "$TMP/ClearKeySmoke"
"$TMP/ClearKeySmoke"
