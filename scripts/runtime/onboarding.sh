#!/bin/bash
# onboarding.sh — Guided first-run setup via the preferred coding assistant.
# Launches an assistant session with a specialized onboarding prompt that walks
# the user through git config, GitHub auth, cloning their first repo, and
# a quick tour of the workspace.
#
# Called from ssh-login.sh when ~/.workspace-initialized doesn't exist.
# Creates ~/.workspace-initialized when the session ends (exit or detach).

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

COMPOSE_DIR="${DEV_ENV:-$HOME/dev-env}"
COMPOSE_CMD=(sudo --preserve-env=HOME docker compose)

if [[ -f "$COMPOSE_DIR/scripts/deploy/load-config.sh" ]]; then
    # shellcheck disable=SC1091
    source "$COMPOSE_DIR/scripts/deploy/load-config.sh"
fi

COMPOSE_DIR="${DEV_ENV:-$COMPOSE_DIR}"
CONTAINER_NAME="${CONTAINER_NAME:-claude-dev}"
ONBOARDING_PROMPT="$COMPOSE_DIR/scripts/runtime/onboarding-prompt.txt"
RUNNER="$COMPOSE_DIR/scripts/runtime/run-code-agent.sh"

normalize_code_agent() {
    case "${1:-}" in
        codex) echo "codex" ;;
        claude|"") echo "claude" ;;
        *) echo "claude" ;;
    esac
}

CODE_AGENT=$(normalize_code_agent "${DEFAULT_CODE_AGENT:-claude}")

export DEFAULT_CODE_AGENT="$CODE_AGENT"
export CONTAINER_NAME

[[ -f "$ONBOARDING_PROMPT" ]] || die "Onboarding prompt not found: $ONBOARDING_PROMPT"
[[ -f "$RUNNER" ]] || die "run-code-agent.sh not found: $RUNNER"

# Start container if not running
if ! sudo docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "  Starting container..."
    (cd "$COMPOSE_DIR" && "${COMPOSE_CMD[@]}" up -d)

    # Wait for container to be ready (up to 30s)
    for i in $(seq 1 30); do
        if sudo docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            break
        fi
        if [[ $i -eq 30 ]]; then
            die "Container failed to start within 30s"
        fi
        sleep 1
    done

    "${COMPOSE_CMD[@]}" exec -u root dev bash -c \
        "chown -R dev:dev /home/dev/projects /home/dev/.claude /home/dev/.codex" 2>/dev/null || true
fi

echo ""
echo "  First-time setup — your coding assistant will walk you through it."
echo ""

tmux new-session -A -s "${CODE_AGENT}-onboarding" \
    "bash -lc 'exec bash \"$RUNNER\" --agent \"$CODE_AGENT\" --cwd \"$COMPOSE_DIR\" --prompt-file \"$ONBOARDING_PROMPT\" --message \"This is my first time here. Help me get set up.\"'"

# Mark onboarding complete when session ends (exit or detach).
# This prevents users from getting stuck in an onboarding loop
# if they disconnect before Claude reaches Step 6 of the prompt.
touch ~/.workspace-initialized
