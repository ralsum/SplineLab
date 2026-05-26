#!/usr/bin/env bash
set -euo pipefail

PORT="${VECTOR_VIEWER_PORT:-8792}"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$BASE_DIR"
