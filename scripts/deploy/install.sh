#!/bin/bash
# install.sh — One-line bootstrap for always-on-claude.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/scripts/deploy/install.sh | bash
#
# Options (env vars):
#   LOCAL_BUILD=1      — build Docker image locally instead of pulling from GHCR
#   NON_INTERACTIVE=1  — skip Phase 2 (interactive auth), for use in user data scripts
#   AOC_SSH_PASSWORD=x  — enable password SSH auth and set password to x
#   AOC_HEARTBEAT_URL=x — configure Claude Code heartbeat hooks (requires AOC_HEARTBEAT_TOKEN)
#   AOC_HEARTBEAT_TOKEN=x — bearer token for heartbeat hooks (requires AOC_HEARTBEAT_URL)
#
# Idempotent — safe to re-run at any point.

set -euo pipefail

# --- Helpers ----------------------------------------------------------------

step=""
trap 'if [ $? -ne 0 ]; then echo ""; echo "ERROR: Failed during: $step"; echo "Fix the issue and re-run — this script is safe to re-run."; fi' ERR

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
skip()  { echo "  SKIP: $* (already done)"; }
die()   { echo "ERROR: $*" >&2; exit 1; }

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

# --- Rename ubuntu user to dev (matches container user) ---------------------

info "System user"
step="rename user"

if id ubuntu &>/dev/null 2>&1 && ! id dev &>/dev/null 2>&1; then
    # Fix sudoers FIRST — after /etc/passwd rename, sudo won't recognize
    # the current user as "ubuntu" so it must already reference "dev"
    if [[ -f /etc/sudoers.d/90-cloud-init-users ]]; then
        sudo sed -i 's/ubuntu/dev/g' /etc/sudoers.d/90-cloud-init-users
    fi

    # Direct file edit avoids usermod's "user is currently logged in" check
    sudo sed -i '/^ubuntu:/ { s/^ubuntu:/dev:/; s|:/home/ubuntu:|:/home/dev:| }' /etc/passwd
    sudo sed -i 's/^ubuntu:/dev:/' /etc/shadow /etc/group /etc/gshadow /etc/subuid /etc/subgid 2>/dev/null || true

    # Move home dir — cd out first so CWD doesn't block the move
    cd /
    sudo mv /home/ubuntu /home/dev

    # Update current session
    export USER=dev
    export HOME=/home/dev
    cd "$HOME"

    ok "Renamed system user ubuntu → dev"
elif id dev &>/dev/null 2>&1; then
    skip "User is already dev"
else
    skip "User is $(id -un) (no rename needed)"
fi

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

if ! command -v jq &>/dev/null; then
    sudo apt-get install -y -qq jq
    ok "jq installed"
else
    skip "jq"
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
    ok "Added $USER to docker group (active after re-login)"
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

# GitHub CLI on host (for workspace management, cloning, PR operations)
if ! command -v gh &>/dev/null; then
    step="GitHub CLI install (host)"
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq gh
    ok "GitHub CLI installed on host"
else
    skip "GitHub CLI (host)"
fi

# Claude Code on host (for orchestrating updates, setup, container management)
if ! command -v claude &>/dev/null; then
    step="Claude Code install (host)"
    curl -fsSL https://claude.ai/install.sh | bash
    ok "Claude Code installed on host"
else
    skip "Claude Code (host)"
fi

# --- Swap -------------------------------------------------------------------

info "Swap"
step="swap setup"

if swapon --show | grep -q '/swapfile'; then
    skip "Swap already active"
else
    sudo fallocate -l 2G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    # Persist across reboots
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
    fi
    # Only swap under real pressure
    sudo sysctl -w vm.swappiness=10 > /dev/null
    if ! grep -q 'vm.swappiness' /etc/sysctl.d/99-swappiness.conf 2>/dev/null; then
        echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf > /dev/null
    fi
    ok "2GB swap enabled (swappiness=10)"
fi

# --- earlyoom ---------------------------------------------------------------

info "earlyoom (OOM prevention)"
step="earlyoom setup"

if systemctl is-active --quiet earlyoom 2>/dev/null; then
    skip "earlyoom already running"
else
    sudo apt-get install -y -qq earlyoom

    # Configure: kill at 5% free RAM / 10% free swap
    # Protect SSH/remote-access daemons, prefer killing Claude/Node
    sudo mkdir -p /etc/default
    cat <<'EOCONF' | sudo tee /etc/default/earlyoom > /dev/null
EARLYOOM_ARGS="-m 5 -s 10 --avoid '(sshd|tailscaled|ssm-agent|systemd)' --prefer '(node|claude)' -r 60 --notify-send"
EOCONF

    sudo systemctl enable --now earlyoom
    ok "earlyoom installed and running"
fi

# --- OOM score protection for critical services -----------------------------

info "OOM score protection"
step="oom score protection"

for svc in ssh tailscaled amazon-ssm-agent; do
    unit_file="/etc/systemd/system/${svc}.service.d/oom.conf"
    if [[ -f "$unit_file" ]]; then
        skip "OOM protection for $svc"
        continue
    fi
    # Only apply if the service actually exists
    if ! systemctl list-unit-files "${svc}.service" &>/dev/null; then
        skip "$svc not installed"
        continue
    fi
    sudo mkdir -p "/etc/systemd/system/${svc}.service.d"
    cat <<'EOCONF' | sudo tee "$unit_file" > /dev/null
[Service]
OOMScoreAdjust=-900
EOCONF
    ok "OOM protection for $svc (score -900)"
done

# Reload systemd to pick up drop-ins
sudo systemctl daemon-reload

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
mkdir -p ~/.config/gh
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
    # shellcheck disable=SC2088
    skip "~/.claude.json"
fi

# SSH known_hosts must exist for bind mount
mkdir -p ~/.ssh
if [[ ! -f ~/.ssh/known_hosts ]]; then
    touch ~/.ssh/known_hosts
    ok "Created ~/.ssh/known_hosts"
else
    # shellcheck disable=SC2088
    skip "~/.ssh/known_hosts"
fi

# Slash commands now live in .claude/commands/ inside the repo
# and are picked up automatically as project-level commands — no copy needed

# Status line script — copy into ~/.claude/ so it's available inside the container
if [[ -f "$DEV_ENV/scripts/runtime/statusline-command.sh" ]]; then
    cp "$DEV_ENV/scripts/runtime/statusline-command.sh" ~/.claude/statusline-command.sh
    chmod +x ~/.claude/statusline-command.sh
    ok "Installed statusline-command.sh"

    # Build desired user-scope settings
    desired='{"permissions":{"defaultMode":"bypassPermissions"},"statusLine":{"type":"command","command":"bash /home/dev/.claude/statusline-command.sh"},"mcpServers":{"context7":{"command":"npx","args":["-y","@upstash/context7-mcp"]},"fetch":{"command":"uvx","args":["mcp-server-fetch"]}}}'

    if [[ -f ~/.claude/settings.json ]]; then
        # Merge desired keys into existing settings (existing keys win only if already correct)
        jq --argjson desired "$desired" '$desired * .' \
            ~/.claude/settings.json > ~/.claude/settings.json.tmp \
            && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
        ok "Merged default settings into settings.json"
    else
        echo "$desired" | jq . > ~/.claude/settings.json
        ok "Created settings.json with default settings"
    fi
fi

# tmux config — host-side status bar with workspace identity, resource usage
if [[ -f "$DEV_ENV/scripts/runtime/tmux.conf" ]]; then
    cp "$DEV_ENV/scripts/runtime/tmux.conf" ~/.tmux.conf
    ok "Installed ~/.tmux.conf"
else
    skip "tmux.conf not found in repo"
fi

if [[ -f "$DEV_ENV/scripts/runtime/tmux-status.sh" ]]; then
    cp "$DEV_ENV/scripts/runtime/tmux-status.sh" ~/.tmux-status.sh
    chmod +x ~/.tmux-status.sh
    ok "Installed ~/.tmux-status.sh"
else
    skip "tmux-status.sh not found in repo"
fi

# Reload tmux config if tmux is running
tmux source-file ~/.tmux.conf 2>/dev/null && ok "Reloaded tmux config" || true

# --- SSH server config --------------------------------------------------------

info "SSH server config"
step="sshd config"

# Allow NO_CLAUDE env var through SSH so users can skip the login menu
if ! grep -q 'NO_CLAUDE' /etc/ssh/sshd_config.d/custom.conf 2>/dev/null; then
    echo 'AcceptEnv NO_CLAUDE' | sudo tee /etc/ssh/sshd_config.d/custom.conf > /dev/null
    sudo systemctl reload ssh
    ok "Added AcceptEnv NO_CLAUDE to sshd"
else
    skip "AcceptEnv NO_CLAUDE already configured"
fi

# --- Shell integration (ssh-login.sh) ---------------------------------------

info "Shell integration"
step="bash_profile setup"

# PATH additions — must be in .bash_profile (not just .bashrc) because
# Ubuntu's .bashrc guards on interactive and exits early for non-interactive
# shells like tmux commands and bash -lc
if ! grep -q '\.local/bin' ~/.bash_profile 2>/dev/null; then
    {
        echo ""
        echo '# PATH additions (must be before .bashrc which guards on interactive)'
        echo 'export PATH="$HOME/.local/bin:$PATH"'
    } >> ~/.bash_profile
    ok "Added ~/.local/bin to PATH in .bash_profile"
else
    # shellcheck disable=SC2088
    skip "~/.local/bin already in .bash_profile PATH"
fi

# Ensure .bash_profile sources .bashrc (bash skips .profile when .bash_profile exists)
if ! grep -q 'source.*bashrc\|\.bashrc' ~/.bash_profile 2>/dev/null; then
    {
        echo ""
        echo "# Source .bashrc (bash skips .profile when .bash_profile exists)"
        echo '[[ -f ~/.bashrc ]] && source ~/.bashrc'
    } >> ~/.bash_profile
    ok "Added .bashrc sourcing to .bash_profile"
else
    skip ".bashrc already sourced from .bash_profile"
fi

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

# --- Auto-updater (systemd timer) -------------------------------------------

info "Auto-updater"
step="auto-updater setup"

bash "$DEV_ENV/scripts/deploy/install-updater.sh"

# --- CloudWatch memory alarms -----------------------------------------------

info "CloudWatch alarms"
step="cloudwatch alarms"

bash "$DEV_ENV/scripts/deploy/install-cloudwatch-alarms.sh" || true

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
    "chown dev:dev /home/dev/projects /home/dev/.claude" 2>/dev/null || true
ok "Fixed container permissions"

echo ""
echo "============================================"
echo "  Phase 1 complete! Container is running."
echo "============================================"

# Mark this host as provisioned (used by slash commands to detect environment)
cat > "$DEV_ENV/.provisioned" <<EOF
provisioned=$(date -u +%Y-%m-%dT%H:%M:%SZ)
commit=$(git -C "$DEV_ENV" rev-parse --short HEAD 2>/dev/null || echo "unknown")
EOF
ok "Wrote provisioned marker"

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

echo ""
echo "============================================"
echo "  Setup complete!"
echo "============================================"
echo ""
echo "  Next steps:"
echo "    1. Log out: exit"
echo "    2. SSH back in: ssh $USER@$(hostname)"
echo "    3. The workspace picker will appear — select a repo to start"
echo ""
