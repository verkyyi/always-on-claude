#!/bin/bash
# Open the Always-On Claude workspace menu from a macOS host.
#
# Intended for a Mac mini reached through host-level SSH/Tailscale SSH. This
# does not start or configure Tailscale; it only uses the local Docker runtime.

set -euo pipefail

DOCKER="${DOCKER:-/opt/homebrew/bin/docker}"
REPO="${AOC_REPO:-$HOME/always-on-claude}"
CONTAINER="${AOC_CONTAINER:-claude-dev}"
COMPOSE_FILE="${AOC_COMPOSE_FILE:-docker-compose.macmini.yml}"

if ! "$DOCKER" ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "$CONTAINER is not running. Starting it..."
  cd "$REPO"
  "$DOCKER" compose -f "$COMPOSE_FILE" up -d
fi

exec "$DOCKER" exec -it "$CONTAINER" bash -lc \
  'exec bash "$HOME/dev-env/scripts/portable/start-claude-portable.sh"'
