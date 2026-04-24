#!/usr/bin/env bash
set -euo pipefail

if [ -f /.dockerenv ]; then
  exec uvx mcp-server-fetch "$@"
fi

if ! docker ps --format '{{.Names}}' | grep -qx 'claude-dev'; then
  echo 'claude-dev container is not running' >&2
  exit 1
fi

exec docker exec -i claude-dev bash -lc 'exec uvx mcp-server-fetch "$@"' bash "$@"
