#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 0
exec python3 .cursor/hooks/harness_hook.py post-shell cursor
