#!/bin/bash
# update-macmini.sh — Update the Mac mini local deployment from source.
#
# Runs on the Mac mini host. It updates the repo, builds the Docker image
# locally from the current checkout, and recreates the container with the same
# persistent bind mounts.

set -euo pipefail

DOCKER="${DOCKER:-/opt/homebrew/bin/docker}"
REPO="${AOC_REPO:-$HOME/always-on-claude}"
COMPOSE_FILE="${AOC_COMPOSE_FILE:-docker-compose.macmini.yml}"
CONTAINER="${AOC_CONTAINER:-claude-dev}"

info() { printf '\n=== %s ===\n' "$*"; }
ok() { printf '  OK: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v "$DOCKER" >/dev/null 2>&1 || die "Docker not found at $DOCKER"
[ -d "$REPO/.git" ] || die "Repo not found: $REPO"

cd "$REPO"

info "Preflight"
"$DOCKER" info >/dev/null 2>&1 || die "Docker daemon is not running"
ok "Docker is running"

if "$DOCKER" ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  sessions=$("$DOCKER" exec "$CONTAINER" bash -lc \
    'tmux list-sessions -F "#{session_name}" 2>/dev/null || true')
  if [ -n "$sessions" ]; then
    printf 'Active tmux sessions inside %s:\n%s\n' "$CONTAINER" "$sessions"
    die "Stop or detach work before updating; recreating the container would end these sessions."
  fi
fi
ok "No active tmux sessions inside container"

info "Repository"
git fetch origin main
git pull --ff-only
revision=$(git rev-parse HEAD)
short_revision=$(git rev-parse --short HEAD)
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ok "Repo at $short_revision"

info "Build"
AOC_IMAGE_REVISION="$revision" AOC_IMAGE_CREATED="$created" \
  "$DOCKER" compose -f "$COMPOSE_FILE" build --pull dev
ok "Image built from $short_revision"

info "Restart"
AOC_IMAGE_REVISION="$revision" AOC_IMAGE_CREATED="$created" \
  "$DOCKER" compose -f "$COMPOSE_FILE" up -d --force-recreate dev
ok "Container recreated"

info "Verify"
"$DOCKER" inspect "$CONTAINER" --format \
  '  Image={{.Image}} Started={{.State.StartedAt}}'
"$DOCKER" image inspect ghcr.io/verkyyi/always-on-claude:latest --format \
  '  Created={{.Created}} Revision={{index .Config.Labels "org.opencontainers.image.revision"}}'
"$DOCKER" exec "$CONTAINER" bash -lc \
  'claude --version; node --version; gh --version | head -1; git --version'

info "Cleanup"
"$DOCKER" image prune -f >/dev/null 2>&1 || true
ok "Done"
