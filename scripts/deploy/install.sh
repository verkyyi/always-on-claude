#!/bin/bash
# install.sh — One-line bootstrap for always-on-claude.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/scripts/deploy/install.sh | bash
#
# Options (env vars):
#   TAILSCALE=1        — install and configure Tailscale for SSH access
#   LOCAL_BUILD=1      — build Docker image locally instead of pulling from GHCR
#   NON_INTERACTIVE=1  — skip Phase 2 (interactive auth), for use in user data scripts
#
# Idempotent — safe to re-run at any point.

set -euo pipefail

# --- Helpers ----------------------------------------------------------------

step=""
trap 'if [ $? -ne 0 ]; then echo ""; echo "ERROR: Failed during: $step"; echo "Fix the issue and re-run — this script is safe to re-run."; fi' ERR

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
skip()  { echo "  SKIP: $* (already done)"; }

TAILSCALE="${TAILSCALE:-0}"
LOCAL_BUILD="${LOCAL_BUILD:-0}"
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
IMAGE="ghcr.io/verkyyi/always-on-claude:latest"

# Wrap sudo: no-op when already root, real sudo otherwise
if [[ $EUID -eq 0 ]]; then
    sudo() { "$@"; }
fi

# --- Phase 1: Automated (no interaction) ------------------------------------

info "Preflight checks"
step="preflight checks"

if [[ "$(uname)" != "Linux" ]]; then
    echo "ERROR: This script requires Linux (designed for Ubuntu 24.04)."
    exit 1
fi

if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
    echo "WARNING: This script is designed for Ubuntu 24.04. Proceeding anyway..."
fi

# Check for required host tools (curl and git ship with Ubuntu 24.04 AMIs
# but may be missing on minimal installs)
missing=()
for cmd in curl git; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
done
if [[ $EUID -ne 0 ]]; then
    command -v sudo &>/dev/null || missing+=("sudo")
fi
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Missing required commands: ${missing[*]}"
    echo "Install them first: apt-get install -y ${missing[*]}"
    exit 1
fi

if ! curl -sfo /dev/null https://get.docker.com; then
    echo "ERROR: No internet connectivity."
    exit 1
fi

ok "Running as $USER ($(if [[ $EUID -eq 0 ]]; then echo "root"; else echo "non-root, using sudo"; fi)) on $(hostname)"

# --- System packages --------------------------------------------------------

info "System packages"
step="system packages"

sudo apt-get update -qq

if ! command -v docker &>/dev/null; then
    step="Docker install"
    curl -fsSL https://get.docker.com | sh
    ok "Docker installed"
else
    skip "Docker"
fi

if ! command -v tmux &>/dev/null; then
    sudo apt-get install -y -qq tmux
    ok "tmux installed"
else
    skip "tmux"
fi

# Ensure Docker Compose plugin is installed
if ! docker compose version &>/dev/null 2>&1; then
    step="Docker Compose plugin"
    sudo apt-get install -y -qq docker-compose-plugin
    ok "Docker Compose plugin installed"
else
    skip "Docker Compose plugin"
fi

# Ensure current user is in docker group (root doesn't need this)
if [[ $EUID -ne 0 ]] && ! id -nG "$USER" | grep -qw docker; then
    sudo usermod -aG docker "$USER"
    ok "Added $USER to docker group (using sg for this session)"
else
    skip "Docker group membership"
fi

# Node.js (needed for Claude Code on host)
if ! command -v node &>/dev/null; then
    step="Node.js install"
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash -
    sudo apt-get install -y -qq nodejs
    ok "Node.js installed"
else
    skip "Node.js"
fi

# Claude Code on host (for orchestrating updates, setup, container management)
if ! command -v claude &>/dev/null; then
    step="Claude Code install (host)"
    curl -fsSL https://claude.ai/install.sh | bash
    ok "Claude Code installed on host"
else
    skip "Claude Code (host)"
fi

# --- Tailscale (optional) --------------------------------------------------

if [[ "$TAILSCALE" == "1" ]]; then
    info "Tailscale"
    step="Tailscale install"

    if ! command -v tailscale &>/dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sh
        ok "Tailscale installed"
    else
        skip "Tailscale binary"
    fi
fi

# --- Clone / update repo ----------------------------------------------------

info "Repository"
step="git clone/pull"

DEV_ENV="$HOME/dev-env"

if [[ -d "$DEV_ENV/.git" ]]; then
    # Already a git clone — pull latest
    git -C "$DEV_ENV" pull --ff-only || true
    ok "Updated existing clone"
elif [[ -d "$DEV_ENV" ]]; then
    # Directory exists but is NOT a git repo (old scp workflow)
    backup="$HOME/dev-env-backup-$(date +%Y%m%d%H%M%S)"
    mv "$DEV_ENV" "$backup"
    echo "  Backed up old $DEV_ENV to $backup"
    git clone https://github.com/verkyyi/always-on-claude.git "$DEV_ENV"
    ok "Cloned (old non-git dir backed up)"
else
    git clone https://github.com/verkyyi/always-on-claude.git "$DEV_ENV"
    ok "Cloned to $DEV_ENV"
fi

# --- Host directories and files --------------------------------------------

info "Host directories and files"
step="host directories"

mkdir -p ~/.claude/commands
mkdir -p ~/.claude/debug
mkdir -p ~/projects
mkdir -p ~/.gitconfig.d

# Critical: must exist as a FILE with valid JSON before compose up
# (Docker would create it as a directory if missing)
if [[ ! -f ~/.claude.json ]]; then
    echo '{}' > ~/.claude.json
    ok "Created ~/.claude.json"
elif [[ ! -s ~/.claude.json ]]; then
    echo '{}' > ~/.claude.json
    ok "Fixed empty ~/.claude.json"
else
    skip "~/.claude.json"
fi

# SSH known_hosts must exist for bind mount
mkdir -p ~/.ssh
if [[ ! -f ~/.ssh/known_hosts ]]; then
    touch ~/.ssh/known_hosts
    ok "Created ~/.ssh/known_hosts"
else
    skip "~/.ssh/known_hosts"
fi

# Slash commands now live in .claude/commands/ inside the repo
# and are picked up automatically as project-level commands — no copy needed

# Status line script — copy into ~/.claude/ so it's available inside the container
if [[ -f "$DEV_ENV/scripts/runtime/statusline-command.sh" ]]; then
    cp "$DEV_ENV/scripts/runtime/statusline-command.sh" ~/.claude/statusline-command.sh
    chmod +x ~/.claude/statusline-command.sh
    ok "Installed statusline-command.sh"

    # Add statusLine config to settings.json if not already present
    if [[ -f ~/.claude/settings.json ]]; then
        if ! jq -e '.statusLine' ~/.claude/settings.json &>/dev/null; then
            jq '. + {"statusLine": {"type": "command", "command": "bash /home/dev/.claude/statusline-command.sh"}}' \
                ~/.claude/settings.json > ~/.claude/settings.json.tmp \
                && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
            ok "Added statusLine to settings.json"
        else
            skip "statusLine already in settings.json"
        fi
    else
        echo '{"statusLine": {"type": "command", "command": "bash /home/dev/.claude/statusline-command.sh"}}' > ~/.claude/settings.json
        ok "Created settings.json with statusLine"
    fi
fi

# --- Shell integration (ssh-login.sh) ---------------------------------------

info "Shell integration"
step="bash_profile setup"

if ! grep -q "ssh-login.sh" ~/.bash_profile 2>/dev/null; then
    {
        echo ""
        echo "# Auto-launch Claude Code on SSH login"
        echo "source ~/dev-env/scripts/runtime/ssh-login.sh"
    } >> ~/.bash_profile
    ok "Added ssh-login.sh to .bash_profile"
else
    skip "ssh-login.sh already in .bash_profile"
fi

# --- Make scripts executable ------------------------------------------------

step="chmod scripts"
chmod +x "$DEV_ENV"/scripts/deploy/*.sh "$DEV_ENV"/scripts/runtime/*.sh 2>/dev/null || true

# --- Docker pull + start ----------------------------------------------------

info "Docker container"
step="docker pull and up"

# Run docker commands — always use sudo for non-root (docker group may not
# be active in the current session even if user was added to it).
# Preserve HOME so ~ in docker-compose.yml resolves to the user's home, not /root.
run_docker() {
    if [[ $EUID -eq 0 ]]; then
        (cd "$DEV_ENV" && "$@")
    else
        (cd "$DEV_ENV" && sudo --preserve-env=HOME "$@")
    fi
}

if [[ "$LOCAL_BUILD" == "1" ]]; then
    echo "  LOCAL_BUILD=1 — building image locally..."
    run_docker docker compose -f docker-compose.yml -f docker-compose.build.yml build
    ok "Image built locally"
else
    step="docker pull"
    if run_docker docker pull "$IMAGE"; then
        ok "Pulled $IMAGE"
    else
        echo "  WARN: Pull failed — falling back to local build..."
        run_docker docker compose -f docker-compose.yml -f docker-compose.build.yml build
        ok "Image built locally (fallback)"
    fi
fi

run_docker docker compose up -d
ok "Container running"

# Fix container permissions (volumes mount as root)
step="fix container permissions"
run_docker docker compose exec -T -u root dev bash -c \
    "chown -R dev:dev /home/dev/projects /home/dev/.claude" 2>/dev/null || true
ok "Fixed container permissions"

echo ""
echo "============================================"
echo "  Phase 1 complete! Container is running."
echo "============================================"

if [[ "$NON_INTERACTIVE" == "1" ]]; then
    echo ""
    echo "  NON_INTERACTIVE mode — skipping auth setup."
    echo "  Run setup-auth.sh manually after SSHing in."
    exit 0
fi

# ============================================================================
# Phase 2: Interactive (browser auth needed)
# ============================================================================

echo ""
echo "Phase 2: Interactive setup (needs browser)"
echo ""

# --- Tailscale auth (optional) ----------------------------------------------

if [[ "$TAILSCALE" == "1" ]]; then
    info "Tailscale authentication"
    step="tailscale auth"

    if tailscale status &>/dev/null 2>&1; then
        skip "Tailscale already connected"
    else
        echo ""
        echo "  Tailscale needs to be connected for SSH access."
        echo "  This will open a URL — paste it in your browser to authenticate."
        echo ""
        read -rp "  Press Enter to run 'sudo tailscale up --ssh'... "
        sudo tailscale up --ssh

        echo ""
        read -rp "  Enter a hostname for this machine (e.g. my-dev-server): " ts_hostname
        if [[ -n "$ts_hostname" ]]; then
            sudo tailscale set --hostname "$ts_hostname"
            ok "Tailscale hostname set to $ts_hostname"
        fi
    fi

    echo ""
    echo "  TIP: Go to https://login.tailscale.com/admin/machines"
    echo "  Select your machine -> SSH -> set access mode to 'Accept'"
    echo "  (This avoids periodic re-authentication prompts)"
    echo ""
fi

# --- In-container auth ------------------------------------------------------

info "Container authentication"
step="container auth"

echo ""
echo "  Now we'll set up git, GitHub CLI, and Claude Code inside the container."
echo ""
read -rp "  Press Enter to continue... "

run_docker docker compose exec -it dev bash /home/dev/dev-env/scripts/deploy/setup-auth.sh </dev/tty

# --- Final verification -----------------------------------------------------

info "Verification"
step="verification"

echo ""

# Check container
if run_docker docker ps --format '{{.Names}}' | grep -q "claude-dev"; then
    ok "Container 'claude-dev' is running"
else
    echo "  WARN: Container not running"
fi

# Check tailscale (only if enabled)
if [[ "$TAILSCALE" == "1" ]]; then
    if tailscale status &>/dev/null 2>&1; then
        ok "Tailscale is connected"
    else
        echo "  WARN: Tailscale not connected"
    fi
fi

echo ""
echo "============================================"
echo "  Setup complete!"
echo "============================================"
echo ""
echo "  Next steps:"
echo "    1. Log out: exit"
echo "    2. SSH back in: ssh $USER@$(hostname)"
echo "    3. The login menu will appear — press Enter for Claude Code"
echo ""
if [[ "$TAILSCALE" == "1" ]] && tailscale status &>/dev/null 2>&1; then
    ts_name=$(tailscale status --self --peers=false | awk '{print $2}' 2>/dev/null || hostname)
    echo "  Or via Tailscale: ssh $USER@$ts_name"
    echo ""
fi
echo "  To lock down the security group (remove public SSH):"
echo "    aws ec2 revoke-security-group-ingress \\"
echo "      --group-id sg-YOUR_SG_ID \\"
echo "      --protocol tcp --port 22 --cidr YOUR_IP/32"
echo ""
