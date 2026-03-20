#!/bin/bash
# manage-users.sh — Add, remove, and list users for multi-user mode.
#
# Usage:
#   manage-users.sh add <username> [--uid <uid>] [--cpu <cpus>] [--memory <mem>]
#   manage-users.sh remove <username>
#   manage-users.sh list
#
# Each user gets:
#   - A Linux user account (for SSH login routing)
#   - A per-user directory tree under ~/users/<username>/
#   - A per-user Docker container (claude-dev-<username>)
#   - Configurable CPU/memory limits
#
# Idempotent — safe to re-run.

set -euo pipefail

# --- Helpers ----------------------------------------------------------------

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
skip()  { echo "  SKIP: $* (already done)"; }
die()   { echo "ERROR: $*" >&2; exit 1; }

# Wrap sudo
if [[ $EUID -eq 0 ]]; then
    sudo() { "$@"; }
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
USERS_DIR="${USERS_BASE_DIR:-/home/dev/users}"
USERS_CONF="$USERS_DIR/.users.conf"

# --- Subcommands ------------------------------------------------------------

cmd_add() {
    local username=""
    local uid_arg=""
    local cpu_limit="1.0"
    local mem_limit="2g"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --uid)    uid_arg="$2"; shift 2 ;;
            --cpu)    cpu_limit="$2"; shift 2 ;;
            --memory) mem_limit="$2"; shift 2 ;;
            -*)       die "Unknown option: $1" ;;
            *)
                if [[ -z "$username" ]]; then
                    username="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    [[ -z "$username" ]] && die "Usage: $0 add <username> [--uid <uid>] [--cpu <cpus>] [--memory <mem>]"

    # Validate username (alphanumeric + hyphens, 2-32 chars)
    if [[ ! "$username" =~ ^[a-z][a-z0-9-]{1,31}$ ]]; then
        die "Invalid username '$username': must start with lowercase letter, contain only lowercase letters, digits, hyphens, and be 2-32 characters"
    fi

    info "Adding user: $username"

    # --- Create Linux user for SSH routing ---
    if id "$username" &>/dev/null; then
        skip "Linux user '$username' already exists"
    else
        local uid_flags=()
        if [[ -n "$uid_arg" ]]; then
            uid_flags=(--uid "$uid_arg")
        fi
        sudo useradd -m -s /bin/bash "${uid_flags[@]}" "$username"
        ok "Created Linux user '$username'"
    fi

    # --- Create per-user directory tree ---
    local user_home="$USERS_DIR/$username"
    mkdir -p "$user_home"/{.claude/commands,.claude/debug,projects,.config/gh,.gitconfig.d,.ssh}

    # Pre-create critical files
    if [[ ! -f "$user_home/.claude.json" ]]; then
        echo '{}' > "$user_home/.claude.json"
    fi
    if [[ ! -f "$user_home/.claude/remote-settings.json" ]]; then
        touch "$user_home/.claude/remote-settings.json"
    fi
    if [[ ! -f "$user_home/.ssh/known_hosts" ]]; then
        touch "$user_home/.ssh/known_hosts"
    fi

    # Copy default settings if available
    if [[ -f /home/dev/.claude/settings.json && ! -f "$user_home/.claude/settings.json" ]]; then
        cp /home/dev/.claude/settings.json "$user_home/.claude/settings.json"
    fi

    # Copy statusline script
    if [[ -f /home/dev/.claude/statusline-command.sh ]]; then
        cp /home/dev/.claude/statusline-command.sh "$user_home/.claude/statusline-command.sh"
        chmod +x "$user_home/.claude/statusline-command.sh"
    fi

    # Fix ownership
    sudo chown -R "$username:$username" "$user_home" 2>/dev/null || true
    ok "Created directory tree at $user_home"

    # --- Copy SSH authorized_keys from the user's Linux home ---
    local linux_home
    linux_home=$(getent passwd "$username" | cut -d: -f6)
    if [[ -f "$linux_home/.ssh/authorized_keys" ]]; then
        cp "$linux_home/.ssh/authorized_keys" "$user_home/.ssh/authorized_keys"
        sudo chown "$username:$username" "$user_home/.ssh/authorized_keys"
        ok "Copied authorized_keys"
    fi

    # --- Set up shell integration for the user ---
    local user_bash_profile="$linux_home/.bash_profile"
    if ! grep -q "ssh-login.sh" "$user_bash_profile" 2>/dev/null; then
        sudo -u "$username" bash -c "cat >> '$user_bash_profile'" <<'PROFILE'

# PATH additions
export PATH="$HOME/.local/bin:$PATH"

# Source .bashrc
[[ -f ~/.bashrc ]] && source ~/.bashrc

# Auto-launch Claude Code on SSH login
source ~/dev-env/scripts/runtime/ssh-login.sh
PROFILE
        ok "Added ssh-login.sh to $username's .bash_profile"
    else
        skip "ssh-login.sh already in $username's .bash_profile"
    fi

    # Symlink dev-env for the user
    if [[ ! -L "$linux_home/dev-env" ]]; then
        sudo ln -sf /home/dev/dev-env "$linux_home/dev-env"
        ok "Symlinked dev-env for $username"
    fi

    # --- Save user config ---
    mkdir -p "$(dirname "$USERS_CONF")"
    # Remove existing entry if present
    if [[ -f "$USERS_CONF" ]]; then
        grep -v "^${username}|" "$USERS_CONF" > "$USERS_CONF.tmp" || true
        mv "$USERS_CONF.tmp" "$USERS_CONF"
    fi
    echo "${username}|${cpu_limit}|${mem_limit}" >> "$USERS_CONF"
    ok "Saved user config (cpu=$cpu_limit, memory=$mem_limit)"

    # --- Generate docker compose file for this user ---
    generate_compose "$username" "$cpu_limit" "$mem_limit"

    # --- Start the container ---
    info "Starting container for $username"
    start_user_container "$username"

    echo ""
    echo "  User '$username' is ready."
    echo "  Container: claude-dev-$username"
    echo "  Projects:  $user_home/projects/"
    echo "  Auth:      SSH in as '$username' then run setup-auth"
    echo ""
}

cmd_remove() {
    local username="$1"
    [[ -z "${username:-}" ]] && die "Usage: $0 remove <username>"

    info "Removing user: $username"

    # Stop and remove the container
    local compose_file="$REPO_DIR/docker-compose.user-${username}.yml"
    if [[ -f "$compose_file" ]]; then
        (cd "$REPO_DIR" && docker compose -f "$compose_file" down 2>/dev/null || true)
        rm -f "$compose_file"
        ok "Stopped and removed container"
    else
        skip "No compose file found"
    fi

    # Remove from users.conf
    if [[ -f "$USERS_CONF" ]]; then
        grep -v "^${username}|" "$USERS_CONF" > "$USERS_CONF.tmp" || true
        mv "$USERS_CONF.tmp" "$USERS_CONF"
    fi
    ok "Removed from users.conf"

    # Note: we do NOT delete the user's data directory or Linux account by default
    echo ""
    echo "  Container removed. User data preserved at $USERS_DIR/$username/"
    echo "  To also remove the Linux user: sudo userdel -r $username"
    echo "  To also remove data: rm -rf $USERS_DIR/$username"
    echo ""
}

cmd_list() {
    if [[ ! -f "$USERS_CONF" ]] || [[ ! -s "$USERS_CONF" ]]; then
        echo ""
        echo "  No multi-user users configured."
        echo "  Add one: $0 add <username>"
        echo ""
        return
    fi

    echo ""
    printf "  %-20s %-8s %-8s %-12s\n" "USERNAME" "CPU" "MEMORY" "STATUS"
    printf "  %-20s %-8s %-8s %-12s\n" "--------" "---" "------" "------"

    while IFS='|' read -r username cpu_limit mem_limit; do
        [[ -z "$username" || "$username" == "#"* ]] && continue
        local status="stopped"
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^claude-dev-${username}$"; then
            status="running"
        fi
        printf "  %-20s %-8s %-8s %-12s\n" "$username" "$cpu_limit" "$mem_limit" "$status"
    done < "$USERS_CONF"
    echo ""
}

# --- Helper functions -------------------------------------------------------

generate_compose() {
    local username="$1" cpu_limit="$2" mem_limit="$3"
    local user_home="$USERS_DIR/$username"
    local compose_file="$REPO_DIR/docker-compose.user-${username}.yml"

    cat > "$compose_file" <<EOF
# Auto-generated by manage-users.sh for user: $username
# Do not edit manually — re-run manage-users.sh add to regenerate.
services:
  dev-${username}:
    image: ghcr.io/verkyyi/always-on-claude:latest
    container_name: claude-dev-${username}
    hostname: claude-dev-${username}
    stdin_open: true
    tty: true
    volumes:
      - ${user_home}/.claude:/home/dev/.claude
      - ${user_home}/.claude.json:/home/dev/.claude.json
      - ${user_home}/.gitconfig.d:/home/dev/.gitconfig.d
      - ${user_home}/projects:/home/dev/projects
      - ${user_home}/.config/gh:/home/dev/.config/gh
      - ${user_home}/.ssh:/home/dev/.ssh
    environment:
      - NODE_ENV=development
    network_mode: host
    restart: unless-stopped
    cpus: ${cpu_limit}
    mem_limit: ${mem_limit}
    mem_reservation: 512m
EOF

    ok "Generated $compose_file"
}

start_user_container() {
    local username="$1"
    local compose_file="$REPO_DIR/docker-compose.user-${username}.yml"

    if [[ ! -f "$compose_file" ]]; then
        die "Compose file not found: $compose_file"
    fi

    local run_cmd=(docker compose -f "$compose_file")
    if [[ $EUID -ne 0 ]]; then
        run_cmd=(sudo --preserve-env=HOME docker compose -f "$compose_file")
    fi

    (cd "$REPO_DIR" && "${run_cmd[@]}" up -d)

    # Fix permissions inside container
    (cd "$REPO_DIR" && "${run_cmd[@]}" exec -T -u root "dev-${username}" bash -c \
        "chown -R dev:dev /home/dev/projects /home/dev/.claude" 2>/dev/null || true)

    ok "Container claude-dev-$username running"
}

# --- Main -------------------------------------------------------------------

case "${1:-}" in
    add)
        shift
        cmd_add "$@"
        ;;
    remove)
        cmd_remove "${2:-}"
        ;;
    list)
        cmd_list
        ;;
    *)
        echo "Usage: $0 {add|remove|list}"
        echo ""
        echo "Commands:"
        echo "  add <username> [--uid N] [--cpu N] [--memory N]"
        echo "      Add a user with optional resource limits"
        echo "      Defaults: --cpu 1.0 --memory 2g"
        echo ""
        echo "  remove <username>"
        echo "      Stop container and remove config (data preserved)"
        echo ""
        echo "  list"
        echo "      Show all configured users and their status"
        exit 1
        ;;
esac
