#!/usr/bin/env bash
set -euo pipefail

PORT="${VECTOR_VIEWER_PORT:-8792}"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_SRC="$BASE_DIR/spline_lab_server.pas"
SERVER_BIN="$BASE_DIR/spline_lab_server"

if [[ ! -x "$SERVER_BIN" || "$SERVER_SRC" -nt "$SERVER_BIN" ]]; then
  fpc -Mdelphi -O3 -B -o"$SERVER_BIN" "$SERVER_SRC"
fi

if [[ -t 0 && -t 1 ]]; then
  exec "$SERVER_BIN" "$PORT"
fi

exec setsid -f "$SERVER_BIN" "$PORT" >>"$BASE_DIR/spline_lab_server.log" 2>&1 < /dev/null
