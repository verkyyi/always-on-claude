#!/bin/bash
# entrypoint.sh — Portable container entrypoint.
#
# Handles first-run setup, starts Tailscale (if configured),
# starts cron/at daemons, and keeps the container alive.
#
# Runs as root initially to start system services,
# then drops privileges to dev user via gosu.

set -euo pipefail

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
skip()  { echo "  SKIP: $* (already done)"; }

# --- First-run setup (idempotent) ------------------------------------------

info "Container init"

# Ensure directories exist with correct ownership
# (volumes may mount as root, or may not exist at all on first run)
for dir in \
    /home/dev/.claude/debug \
    /home/dev/.claude/commands \
    /home/dev/.config/gh \
    /home/dev/projects \
    /home/dev/overnight; do
    mkdir -p "$dir"
done

# .claude.json must be a file (not a directory) — store the real file inside
# the claude-data volume and symlink to it, avoiding the Docker named-volume
# gotcha where mounting a volume to a file path creates a directory instead
CLAUDE_JSON_REAL="/home/dev/.claude/claude.json"
CLAUDE_JSON_LINK="/home/dev/.claude.json"

if [[ ! -f "$CLAUDE_JSON_REAL" ]]; then
    echo '{}' > "$CLAUDE_JSON_REAL"
    ok "Created .claude/claude.json"
fi

# Remove stale symlink, directory, or regular file and replace with symlink
if [[ -d "$CLAUDE_JSON_LINK" ]]; then
    rmdir "$CLAUDE_JSON_LINK" 2>/dev/null || rm -rf "$CLAUDE_JSON_LINK"
fi
if [[ ! -L "$CLAUDE_JSON_LINK" ]]; then
    rm -f "$CLAUDE_JSON_LINK"
    ln -s "$CLAUDE_JSON_REAL" "$CLAUDE_JSON_LINK"
    ok "Symlinked .claude.json -> .claude/claude.json"
fi

# remote-settings.json must exist or Claude crashes
if [[ ! -f /home/dev/.claude/remote-settings.json ]]; then
    touch /home/dev/.claude/remote-settings.json
    ok "Created remote-settings.json"
fi

# settings.json — set up default settings if not present
if [[ ! -f /home/dev/.claude/settings.json ]]; then
    desired='{"permissions":{"defaultMode":"bypassPermissions"},"statusLine":{"type":"command","command":"bash /home/dev/.claude/statusline-command.sh"}}'
    echo "$desired" | jq . > /home/dev/.claude/settings.json 2>/dev/null || echo "$desired" > /home/dev/.claude/settings.json
    ok "Created default settings.json"
fi

# Install statusline script if it shipped with the image
if [[ -f /home/dev/dev-env/scripts/runtime/statusline-command.sh ]]; then
    cp /home/dev/dev-env/scripts/runtime/statusline-command.sh /home/dev/.claude/statusline-command.sh
    chmod +x /home/dev/.claude/statusline-command.sh
fi

# Install tmux config
if [[ -f /home/dev/dev-env/scripts/runtime/tmux.conf ]]; then
    cp /home/dev/dev-env/scripts/runtime/tmux.conf /home/dev/.tmux.conf
fi
if [[ -f /home/dev/dev-env/scripts/runtime/tmux-status.sh ]]; then
    cp /home/dev/dev-env/scripts/runtime/tmux-status.sh /home/dev/.tmux-status.sh
    chmod +x /home/dev/.tmux-status.sh
fi

# Fix ownership on everything
chown -R dev:dev /home/dev/.claude \
    /home/dev/.config /home/dev/projects /home/dev/overnight \
    /home/dev/.tmux.conf /home/dev/.tmux-status.sh 2>/dev/null || true
chown -h dev:dev /home/dev/.claude.json 2>/dev/null || true

ok "Directories and config ready"

# --- .bash_profile setup (portable mode) -----------------------------------

# Set up .bash_profile for the dev user so SSH/Tailscale login triggers
# the workspace picker. Only writes if not already configured.
BASH_PROFILE="/home/dev/.bash_profile"

if [[ ! -f "$BASH_PROFILE" ]] || ! grep -q 'ssh-login-portable' "$BASH_PROFILE" 2>/dev/null; then
    cat > "$BASH_PROFILE" <<'PROFILE'
# PATH additions
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"

# Source .bashrc
[[ -f ~/.bashrc ]] && source ~/.bashrc

# Auto-launch Claude Code on interactive login (portable mode)
# shellcheck source=scripts/portable/ssh-login-portable.sh
source ~/dev-env/scripts/portable/ssh-login-portable.sh
PROFILE
    chown dev:dev "$BASH_PROFILE"
    ok "Configured .bash_profile (portable mode)"
else
    skip ".bash_profile already configured"
fi

# --- Tailscale (optional) --------------------------------------------------

if command -v tailscaled &>/dev/null; then
    info "Tailscale"

    # Start tailscaled in the background
    tailscaled --state=/var/lib/tailscale/tailscaled.state --tun=userspace-networking &
    TAILSCALED_PID=$!

    # Wait for tailscaled to be ready (up to 10s)
    for i in $(seq 10); do tailscale status &>/dev/null && break; sleep 1; done

    TS_HOSTNAME="${TS_HOSTNAME:-claude-dev}"

    if [[ -n "${TS_AUTHKEY:-}" ]]; then
        # Non-interactive: use auth key
        tailscale up --ssh --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME"
        ok "Tailscale connected (hostname: $TS_HOSTNAME)"
    elif tailscale status &>/dev/null 2>&1; then
        # Already authenticated from persisted state
        tailscale up --ssh --hostname="$TS_HOSTNAME"
        ok "Tailscale reconnected (hostname: $TS_HOSTNAME)"
    else
        # No auth key and no persisted state — print instructions
        echo "  Tailscale not authenticated."
        echo "  To connect, exec into the container and run:"
        echo "    tailscale up --ssh --hostname=$TS_HOSTNAME"
        echo "  Or restart with TS_AUTHKEY set."
    fi
else
    skip "Tailscale not installed"
fi

# --- cron + at daemons (optional, for overnight scheduling) ----------------

if command -v cron &>/dev/null; then
    cron
    ok "cron daemon started"
fi

if command -v atd &>/dev/null; then
    atd
    ok "at daemon started"
fi

# --- Keep container alive --------------------------------------------------

info "Ready"
echo ""
echo "  Container is running. Connect via:"
echo "    docker exec -it claude-dev bash -l"
echo ""
if command -v tailscale &>/dev/null && tailscale status &>/dev/null 2>&1; then
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
    echo "  Or via Tailscale SSH:"
    echo "    ssh dev@${TS_HOSTNAME:-claude-dev}  (IP: $TS_IP)"
    echo ""
fi

# Drop privileges — the container should not idle as root
if command -v gosu &>/dev/null; then
    exec gosu dev sleep infinity
else
    exec su - dev -c 'sleep infinity'
fi
