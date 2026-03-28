#!/bin/bash
# self-update.sh — Single command to update the entire dev environment.
#
# Flow: fetch → preview → confirm → apply
#
#   1. Fetch latest changes (without applying)
#   2. Preview all changes grouped by impact
#   3. Ask user to confirm
#   4. Apply: pull, update image, copy host scripts
#
# Run manually or via the /update slash command.
# Preserves running tmux sessions — only restarts container when necessary.

set -euo pipefail

# --- Helpers ----------------------------------------------------------------

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
skip()  { echo "  SKIP: $* (already done)"; }
warn()  { echo "  WARN: $*"; }
die()   { echo "ERROR: $*" >&2; exit 1; }

DEV_ENV="${DEV_ENV:-$HOME/dev-env}"
TARGET_BRANCH="${TARGET_BRANCH:-main}"
UPDATED=()
NEEDS_RESTART=false
AUTO_YES="${AUTO_YES:-false}"

# Build the correct docker compose command
docker_compose() {
    if [[ $EUID -eq 0 ]]; then
        (cd "$DEV_ENV" && docker compose "$@")
    else
        (cd "$DEV_ENV" && sudo --preserve-env=HOME docker compose "$@")
    fi
}

docker_cmd() {
    if [[ $EUID -eq 0 ]]; then
        docker "$@"
    else
        sudo docker "$@"
    fi
}

# --- Preflight --------------------------------------------------------------

if [[ ! -d "$DEV_ENV/.git" ]]; then
    die "$DEV_ENV is not a git repo. Run install.sh first."
fi

info "Checking for updates"
echo "  Dev env: $DEV_ENV"

# --- Step 1: Fetch (don't pull yet) ----------------------------------------

info "Step 1/4: Fetching latest changes"

current_branch=$(git -C "$DEV_ENV" branch --show-current)
before=$(git -C "$DEV_ENV" rev-parse HEAD)
git -C "$DEV_ENV" fetch --quiet origin 2>&1

# Always compare against origin/main, not the current branch upstream
upstream=$(git -C "$DEV_ENV" rev-parse "origin/$TARGET_BRANCH" 2>/dev/null || echo "$before")

BRANCH_SWITCH=false
if [[ "$current_branch" != "$TARGET_BRANCH" ]]; then
    BRANCH_SWITCH=true
    echo "  Currently on branch '$current_branch' — will switch to '$TARGET_BRANCH'"
fi

# Check for local uncommitted changes
local_changes=$(git -C "$DEV_ENV" status --porcelain 2>/dev/null || true)
if [[ -n "$local_changes" ]]; then
    echo "  Local changes detected (will stash and restore):"
    echo "$local_changes" | sed 's/^/    /'
fi

if [[ "$before" == "$upstream" && "$BRANCH_SWITCH" == "false" ]]; then
    skip "Repo already up to date"
    CHANGED_FILES=""
else
    echo "  ${before:0:7}..${upstream:0:7} ($(git -C "$DEV_ENV" rev-list --count "${before}..${upstream}") commits)"
    CHANGED_FILES=$(git -C "$DEV_ENV" diff --name-only "${before}..${upstream}")
fi

# Also check for Docker image updates (regardless of repo changes)
IMAGE="ghcr.io/verkyyi/always-on-claude:latest"
local_digest_before=$(docker_cmd inspect --format='{{.Id}}' "$IMAGE" 2>/dev/null || echo "none")

# --- Step 2: Preview all changes -------------------------------------------

info "Step 2/4: Preview"

has_changes=false

if [[ "$BRANCH_SWITCH" == "true" ]]; then
    has_changes=true
    echo ""
    echo "  Branch: $current_branch -> $TARGET_BRANCH"
fi

# Categorize changed files by impact area
if [[ -n "$CHANGED_FILES" ]]; then
    # Container restart required
    container_changes=$(echo "$CHANGED_FILES" | grep -E '^(Dockerfile|docker-compose\.yml|docker-compose\.build\.yml)$' || true)

    # Runtime scripts (take effect on git pull — bind mounted or run from ~/dev-env)
    runtime_changes=$(echo "$CHANGED_FILES" | grep -E '^scripts/runtime/' || true)

    # Deploy/install scripts (provision-time only, informational)
    deploy_changes=$(echo "$CHANGED_FILES" | grep -E '^scripts/deploy/' || true)

    # Slash commands (take effect on git pull — bind mounted)
    command_changes=$(echo "$CHANGED_FILES" | grep -E '^\.claude/commands/' || true)

    # Docs and config (no runtime impact)
    doc_changes=$(echo "$CHANGED_FILES" | grep -E '^(docs/|CLAUDE\.md|README\.md|\.github/|\.env\.example|\.gitignore|\.dockerignore|tests/)' || true)

    # Everything else
    other_changes=$(echo "$CHANGED_FILES" | grep -vE '^(Dockerfile|docker-compose\.yml|docker-compose\.build\.yml|scripts/runtime/|scripts/deploy/|\.claude/commands/|docs/|CLAUDE\.md|README\.md|\.github/|\.env\.example|\.gitignore|\.dockerignore|tests/)' || true)

    # Show commits
    echo ""
    echo "  Commits:"
    git -C "$DEV_ENV" log --oneline "${before}..${upstream}" | sed 's/^/    /'

    # Container restart
    if [[ -n "$container_changes" ]]; then
        has_changes=true
        echo ""
        echo "  Container (restart required):"
        echo "$container_changes" | sed 's/^/    /'
    fi

    # Runtime scripts
    if [[ -n "$runtime_changes" ]]; then
        has_changes=true
        echo ""
        echo "  Runtime scripts (take effect immediately after pull):"
        echo "$runtime_changes" | sed 's/^/    /'
    fi

    # Slash commands
    if [[ -n "$command_changes" ]]; then
        has_changes=true
        echo ""
        echo "  Slash commands (take effect immediately after pull):"
        echo "$command_changes" | sed 's/^/    /'
    fi

    # Host-side scripts that need copying
    host_copy_changes=""
    if [[ -n "$runtime_changes" ]]; then
        host_copy_changes=$(echo "$runtime_changes" | grep -E '(statusline-command\.sh|tmux\.conf|tmux-status\.sh)$' || true)
    fi
    if [[ -n "$host_copy_changes" ]]; then
        echo ""
        echo "  Host-side configs (will be copied outside repo):"
        echo "$host_copy_changes" | sed 's/^/    /'
    fi

    # Deploy scripts (informational)
    if [[ -n "$deploy_changes" ]]; then
        echo ""
        echo "  Deploy scripts (provision-time only, no runtime effect):"
        echo "$deploy_changes" | sed 's/^/    /'
    fi

    # Docs
    if [[ -n "$doc_changes" ]]; then
        echo ""
        echo "  Docs/CI/config (no runtime effect):"
        echo "$doc_changes" | sed 's/^/    /'
    fi

    # Other
    if [[ -n "$other_changes" ]]; then
        has_changes=true
        echo ""
        echo "  Other:"
        echo "$other_changes" | sed 's/^/    /'
    fi
else
    echo "  No repo changes."
fi

# Check Docker image (lightweight — just check remote digest without pulling)
echo ""
echo "  Checking Docker image registry..."
remote_digest=$(docker_cmd manifest inspect "$IMAGE" 2>/dev/null | grep -m1 '"digest"' | cut -d'"' -f4 || echo "unknown")
if [[ "$local_digest_before" == "none" ]]; then
    echo "  No local image — will pull"
    IMAGE_NEEDS_PULL=true
    has_changes=true
elif [[ "$remote_digest" == "unknown" ]]; then
    echo "  Could not check remote digest — will pull to verify"
    IMAGE_NEEDS_PULL=true
    has_changes=true
else
    # Compare local repo digest with what compose would use
    local_repo_digest=$(docker_cmd inspect --format='{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null | cut -d'@' -f2 || echo "none")
    if [[ "$local_repo_digest" != "$remote_digest" ]]; then
        echo "  Newer image available in registry"
        IMAGE_NEEDS_PULL=true
        has_changes=true
    else
        echo "  Docker image already latest"
        IMAGE_NEEDS_PULL=false
    fi
fi

IMAGE_NEEDS_RESTART=false
if [[ "${IMAGE_NEEDS_PULL:-false}" == "true" || -n "${container_changes:-}" ]]; then
    IMAGE_NEEDS_RESTART=true
fi

# Active sessions warning
if [[ "$IMAGE_NEEDS_RESTART" == "true" ]]; then
    active_sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E '^(claude-|shell-)' || true)
    if [[ -n "$active_sessions" ]]; then
        echo ""
        warn "Active sessions (will survive restart — tmux runs on host):"
        while IFS= read -r session; do echo "      $session"; done <<< "$active_sessions"
    fi
fi

# Nothing to do?
if [[ "$has_changes" == "false" && "${IMAGE_NEEDS_PULL:-false}" == "false" ]]; then
    echo ""
    echo "  Everything is up to date. Nothing to do."
    echo ""
    rm -f "$HOME/.update-pending"
    exit 0
fi

# --- Step 3: Confirm -------------------------------------------------------

info "Step 3/4: Confirm"

if [[ "$AUTO_YES" == "true" ]]; then
    echo "  AUTO_YES=true — proceeding"
elif [[ -t 0 ]]; then
    echo ""
    if [[ "$IMAGE_NEEDS_RESTART" == "true" ]]; then
        echo "  This update will restart the container."
    fi
    read -rp "  Apply updates? [y/N] " confirm
    if [[ "$confirm" != [yY] ]]; then
        echo "  Aborted. No changes applied."
        exit 0
    fi
else
    # Non-interactive (called from Claude): proceed — Claude already showed preview
    echo "  Non-interactive mode — proceeding"
fi

# --- Step 4: Apply ---------------------------------------------------------

info "Step 4/4: Applying updates"

# 4a. Pull repo changes
if [[ "$before" != "$upstream" || "$BRANCH_SWITCH" == "true" ]]; then
    # Stash local changes if any
    stashed=false
    if [[ -n "$local_changes" ]]; then
        git -C "$DEV_ENV" stash push -m "self-update $(date +%Y%m%d-%H%M%S)" 2>&1
        stashed=true
        ok "Stashed local changes"
    fi

    # Switch to target branch if needed
    if [[ "$BRANCH_SWITCH" == "true" ]]; then
        git -C "$DEV_ENV" checkout "$TARGET_BRANCH" 2>&1
        ok "Switched to $TARGET_BRANCH"
    fi

    # Pull latest
    if git -C "$DEV_ENV" pull --ff-only 2>&1; then
        after=$(git -C "$DEV_ENV" rev-parse HEAD)
        ok "Repo updated (${before:0:7}..${after:0:7})"
        UPDATED+=("repo: ${before:0:7}..${after:0:7}")
    else
        warn "git pull --ff-only failed (divergent history?). Skipping repo update."
    fi

    # Restore stashed changes
    if [[ "$stashed" == "true" ]]; then
        if git -C "$DEV_ENV" stash pop 2>&1; then
            ok "Restored local changes"
        else
            warn "Stash pop had conflicts — local changes saved in git stash"
            UPDATED+=("warning: stash pop conflicts, run 'git -C ~/dev-env stash pop' manually")
        fi
    fi

    # Make all scripts executable
    chmod +x "$DEV_ENV"/scripts/deploy/*.sh "$DEV_ENV"/scripts/runtime/*.sh 2>/dev/null || true
fi

# 4b. Docker image
if [[ "$IMAGE_NEEDS_RESTART" == "true" ]]; then
    echo "  Pulling latest image..."
    docker_cmd pull "$IMAGE" 2>&1

    # Check for active sessions — ask about restart timing
    active_sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E '^(claude-|shell-)' || true)
    do_restart=true

    if [[ -n "$active_sessions" && "$AUTO_YES" != "true" && -t 0 ]]; then
        echo ""
        warn "Active sessions detected. Container restart will briefly disconnect docker exec sessions."
        read -rp "  Restart container now? [y/N] " restart_confirm
        if [[ "$restart_confirm" != [yY] ]]; then
            do_restart=false
            NEEDS_RESTART=true
        fi
    fi

    if [[ "$do_restart" == "true" ]]; then
        docker_compose up -d 2>&1
        # Fix container permissions after restart
        docker_compose exec -T -u root dev bash -c \
            "chown -R dev:dev /home/dev/projects /home/dev/.claude" 2>/dev/null || true
        # Clean up old images
        docker_cmd image prune -f 2>/dev/null || true
        ok "Container restarted with updated image"
        UPDATED+=("docker-image: updated and restarted")
    else
        UPDATED+=("docker-image: pulled, restart pending")
    fi
elif [[ "${IMAGE_NEEDS_PULL:-false}" == "true" ]]; then
    echo "  Pulling latest image..."
    docker_cmd pull "$IMAGE" 2>&1
    skip "Image pulled but no restart needed"
fi

# 4c. Host-side scripts (copied outside the repo)
host_updated=false

if [[ -f "$DEV_ENV/scripts/runtime/statusline-command.sh" ]]; then
    if ! cmp -s "$DEV_ENV/scripts/runtime/statusline-command.sh" ~/.claude/statusline-command.sh 2>/dev/null; then
        cp "$DEV_ENV/scripts/runtime/statusline-command.sh" ~/.claude/statusline-command.sh
        chmod +x ~/.claude/statusline-command.sh
        ok "Updated statusline-command.sh"
        host_updated=true
    fi
fi

if [[ -f "$DEV_ENV/scripts/runtime/tmux.conf" ]]; then
    if ! cmp -s "$DEV_ENV/scripts/runtime/tmux.conf" ~/.tmux.conf 2>/dev/null; then
        cp "$DEV_ENV/scripts/runtime/tmux.conf" ~/.tmux.conf
        ok "Updated ~/.tmux.conf"
        tmux source-file ~/.tmux.conf 2>/dev/null && ok "Reloaded tmux config" || true
        host_updated=true
    fi
fi

if [[ -f "$DEV_ENV/scripts/runtime/tmux-status.sh" ]]; then
    if ! cmp -s "$DEV_ENV/scripts/runtime/tmux-status.sh" ~/.tmux-status.sh 2>/dev/null; then
        cp "$DEV_ENV/scripts/runtime/tmux-status.sh" ~/.tmux-status.sh
        chmod +x ~/.tmux-status.sh
        ok "Updated ~/.tmux-status.sh"
        host_updated=true
    fi
fi

if [[ "$host_updated" == "true" ]]; then
    UPDATED+=("host-scripts: updated")
fi

# --- Summary ----------------------------------------------------------------

echo ""
echo "=== Summary ==="

rm -f "$HOME/.update-pending"

if [[ ${#UPDATED[@]} -eq 0 ]]; then
    echo ""
    echo "  Everything is up to date. No changes applied."
else
    echo ""
    echo "  Updates applied:"
    for item in "${UPDATED[@]}"; do
        echo "    - $item"
    done
fi

if [[ "$NEEDS_RESTART" == "true" ]]; then
    echo ""
    echo "  NOTE: Container restart is pending. Run this script again or restart manually:"
    echo "    cd ~/dev-env && sudo --preserve-env=HOME docker compose up -d"
fi

echo ""
echo "  Done."
