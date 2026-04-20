#!/bin/bash
# install.sh — One-line bootstrap for always-on-claude.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/scripts/deploy/install.sh | bash
#
# Options (env vars):
#   LOCAL_BUILD=1      — build Docker image locally instead of pulling from GHCR
#   NON_INTERACTIVE=1  — (no longer used, kept for backward compatibility with callers)
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

# Load config if available (repo may not be cloned yet on first run)
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_SCRIPT_DIR/load-config.sh" ]]; then
    # shellcheck disable=SC1091
    source "$_SCRIPT_DIR/load-config.sh"
else
    # Fallback defaults when running via curl pipe before repo exists
    : "${DOCKER_IMAGE:=ghcr.io/verkyyi/always-on-claude:latest}"
    : "${DEV_ENV:=$HOME/dev-env}"
    : "${PROJECTS_DIR:=$HOME/projects}"
    : "${CONTAINER_NAME:=claude-dev}"
    IMAGE="$DOCKER_IMAGE"
fi

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

# --- Verify dev user exists --------------------------------------------------
# The dev user is created by cloud-init via user-data (cloud-config) before
# install.sh runs. Both build-ami.sh and /provision pass system_info config
# that creates dev instead of the default ubuntu user.

info "System user"
step="verify dev user"

if id dev &>/dev/null 2>&1; then
    ok "User dev exists"
else
    die "Expected 'dev' user to exist. Ensure cloud-config user-data creates it before running install.sh."
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

# Ensure dev user is in docker group
if ! id -nG dev 2>/dev/null | grep -qw docker; then
    sudo usermod -aG docker dev
    ok "Added dev to docker group"
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

# AWS CLI v2 on host (for workspace management scripts, backups, CloudWatch)
if ! command -v aws &>/dev/null; then
    step="AWS CLI v2 install (host)"
    sudo apt-get install -y -qq unzip
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip
    unzip -qo /tmp/awscliv2.zip -d /tmp
    sudo /tmp/aws/install
    rm -rf /tmp/aws /tmp/awscliv2.zip
    ok "AWS CLI v2 installed on host"
else
    skip "AWS CLI v2 (host)"
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

# DEV_ENV is set by load-config.sh (or fallback defaults above)

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

# Re-source config now that repo exists (picks up .env if present)
if [[ -f "$DEV_ENV/scripts/deploy/load-config.sh" ]]; then
    # shellcheck disable=SC1091
    source "$DEV_ENV/scripts/deploy/load-config.sh"
fi

# --- Host directories and files --------------------------------------------

info "Host directories and files"
step="host directories"

mkdir -p ~/.claude/commands
mkdir -p ~/.claude/debug
mkdir -p ~/.config/gh
mkdir -p "$PROJECTS_DIR"
mkdir -p ~/.gitconfig.d
mkdir -p ~/.aws

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

# --- Heartbeat hook validation ------------------------------------------------

if [[ -n "${AOC_HEARTBEAT_URL:-}" && -z "${AOC_HEARTBEAT_TOKEN:-}" ]] || \
   [[ -z "${AOC_HEARTBEAT_URL:-}" && -n "${AOC_HEARTBEAT_TOKEN:-}" ]]; then
    echo "  WARN: Both AOC_HEARTBEAT_URL and AOC_HEARTBEAT_TOKEN must be set. Skipping heartbeat hooks."
    unset AOC_HEARTBEAT_URL AOC_HEARTBEAT_TOKEN
fi

# Status line script — copy into ~/.claude/ so it's available inside the container
if [[ -f "$DEV_ENV/scripts/runtime/statusline-command.sh" ]]; then
    cp "$DEV_ENV/scripts/runtime/statusline-command.sh" ~/.claude/statusline-command.sh
    chmod +x ~/.claude/statusline-command.sh
    ok "Installed statusline-command.sh"

    # GitHub MCP auth bridge — sourced by start-claude*.sh to export
    # GITHUB_PERSONAL_ACCESS_TOKEN from gh CLI auth state.
    if [[ -f "$DEV_ENV/scripts/runtime/gh-mcp-env.sh" ]]; then
        cp "$DEV_ENV/scripts/runtime/gh-mcp-env.sh" ~/.claude/gh-mcp-env.sh
        chmod +x ~/.claude/gh-mcp-env.sh
        ok "Installed gh-mcp-env.sh"
    fi

    # Build desired user-scope settings
    desired='{"permissions":{"defaultMode":"bypassPermissions"},"statusLine":{"type":"command","command":"bash /home/dev/.claude/statusline-command.sh"},"mcpServers":{"context7":{"command":"npx","args":["-y","@upstash/context7-mcp"]},"fetch":{"command":"uvx","args":["mcp-server-fetch"]}}}'

    # Merge heartbeat hooks if configured (use jq --arg for safe escaping)
    if [[ -n "${AOC_HEARTBEAT_URL:-}" && -n "${AOC_HEARTBEAT_TOKEN:-}" ]]; then
        heartbeat_hooks=$(jq -n \
            --arg url "$AOC_HEARTBEAT_URL" \
            --arg token "$AOC_HEARTBEAT_TOKEN" \
            '{hooks: {
                Notification: [{matcher: "idle_prompt", hooks: [{type: "http", url: $url, headers: {Authorization: ("Bearer " + $token)}}]}],
                Stop: [{matcher: "", hooks: [{type: "http", url: $url, headers: {Authorization: ("Bearer " + $token)}}]}],
                SessionStart: [{matcher: "", hooks: [{type: "http", url: $url, headers: {Authorization: ("Bearer " + $token)}}]}]
            }}')
        desired=$(echo "$desired" | jq --argjson hb "$heartbeat_hooks" '. * $hb')
        ok "Added heartbeat hooks to settings"
    fi

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

# Global CLAUDE.md — user-scope instructions shared across all projects.
# Install once if missing; leave user edits alone on re-runs.
if [[ -f "$DEV_ENV/scripts/runtime/claude-global.md" ]]; then
    if [[ -f ~/.claude/CLAUDE.md ]]; then
        # shellcheck disable=SC2088
        skip "~/.claude/CLAUDE.md"
    else
        cp "$DEV_ENV/scripts/runtime/claude-global.md" ~/.claude/CLAUDE.md
        # shellcheck disable=SC2088
        ok "Installed ~/.claude/CLAUDE.md"
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

# Build custom.conf content — single write to avoid clobber issues
SSHD_CUSTOM="AcceptEnv NO_CLAUDE"

if [[ -n "${AOC_SSH_PASSWORD:-}" ]]; then
    SSHD_CUSTOM="${SSHD_CUSTOM}
PasswordAuthentication yes
KbdInteractiveAuthentication yes"
fi

# Only write if content changed (preserves idempotency)
if [[ ! -f /etc/ssh/sshd_config.d/custom.conf ]] || \
   ! echo "$SSHD_CUSTOM" | diff -q - /etc/ssh/sshd_config.d/custom.conf &>/dev/null; then
    echo "$SSHD_CUSTOM" | sudo tee /etc/ssh/sshd_config.d/custom.conf > /dev/null
    sudo systemctl reload ssh
    ok "Wrote sshd custom config"
else
    skip "sshd custom config"
fi

# Set password if requested
if [[ -n "${AOC_SSH_PASSWORD:-}" ]]; then
    echo "${USER}:${AOC_SSH_PASSWORD}" | sudo chpasswd
    ok "Set SSH password for $USER"
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

# --- Cloud-init config (for pre-baked AMI boots) -----------------------------

info "Cloud-init config"
step="cloud-init config"

# Tell cloud-init the default user is 'dev' (not 'ubuntu').
# On pre-baked AMI boots, cloud-init creates this user and injects the EC2 SSH
# key — so the user can SSH as dev@ immediately without User Data running.
CLOUDINIT_CFG="/etc/cloud/cloud.cfg.d/99-always-on-claude.cfg"
if [[ ! -f "$CLOUDINIT_CFG" ]]; then
    cat <<'CLOUDINIT' | sudo tee "$CLOUDINIT_CFG" > /dev/null
# Top-level groups: ensures dev gets added to docker/sudo on pre-baked AMI
# boots. cloud-init's add_user() skips groups for existing users, but
# create_group() always runs usermod -a -G for listed members.
groups:
  - docker: [dev]
  - sudo: [dev]

system_info:
  default_user:
    name: dev
    lock_passwd: false
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [docker, sudo]
    gecos: Developer
    homedir: /home/dev
CLOUDINIT
    ok "Wrote cloud-init config (default user: dev)"
else
    skip "cloud-init config"
fi

# --- Container boot service (systemd) ----------------------------------------

info "Container boot service"
step="systemd service"

SERVICE_NAME="always-on-claude"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

cat <<EOF | sudo tee "$SERVICE_FILE" > /dev/null
[Unit]
Description=Always-on Claude Code container
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=HOME=/home/dev
WorkingDirectory=$DEV_ENV
ExecStartPre=/usr/bin/git -C $DEV_ENV pull --ff-only
ExecStart=/usr/bin/docker compose up -d --force-recreate
ExecStop=/usr/bin/docker compose stop

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME" 2>/dev/null
ok "Systemd service installed and enabled"

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

# Fix permissions (volumes mount as root, aws cli may create ~/.aws as root)
step="fix permissions"
run_docker docker compose exec -T -u root dev bash -c \
    "chown dev:dev /home/dev/projects /home/dev/.claude" 2>/dev/null || true
[[ -d "$HOME/.aws" ]] && sudo chown -R "$(id -u dev):$(id -g dev)" "$HOME/.aws" 2>/dev/null || true
ok "Fixed permissions"

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

echo ""
echo "  Connect via SSH to complete setup — Claude will guide you through auth."
