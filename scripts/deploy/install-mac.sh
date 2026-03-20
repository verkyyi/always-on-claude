#!/bin/bash
# install-mac.sh — Bootstrap always-on-claude on a local Mac.
#
# Usage:
#   bash install-mac.sh
#
# Options (env vars):
#   LOCAL_BUILD=1      — build Docker image locally instead of pulling from GHCR
#   NON_INTERACTIVE=1  — skip Phase 2 (interactive auth)
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

# --- Phase 1: Automated (no interaction) ------------------------------------

info "Preflight checks"
step="preflight checks"

if [[ "$(uname)" != "Darwin" ]]; then
    die "This script requires macOS. For Linux/EC2, use install.sh instead."
fi

# Check for Xcode CLI tools (needed for git, compilers, etc.)
if ! xcode-select -p &>/dev/null; then
    echo "  Xcode Command Line Tools not found. Installing..."
    xcode-select --install
    echo ""
    echo "  A dialog should have appeared. Click 'Install' and wait for it to finish."
    echo "  Then re-run this script."
    exit 1
fi

if ! curl -sfo /dev/null https://get.docker.com; then
    die "No internet connectivity."
fi

ok "Running on macOS $(sw_vers -productVersion) ($(uname -m))"

# --- Homebrew ---------------------------------------------------------------

info "Homebrew"
step="homebrew"

if ! command -v brew &>/dev/null; then
    echo "  Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add to current session (Apple Silicon vs Intel)
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -f /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
    ok "Homebrew installed"
else
    skip "Homebrew"
fi

# --- System packages via Homebrew -------------------------------------------

info "System packages"
step="system packages"

BREW_PACKAGES=(tmux git gh node@22 jq ripgrep fzf)

for pkg in "${BREW_PACKAGES[@]}"; do
    if brew list "$pkg" &>/dev/null; then
        skip "$pkg"
    else
        brew install "$pkg"
        ok "$pkg installed"
    fi
done

# Ensure node@22 is linked (it's keg-only)
if ! command -v node &>/dev/null; then
    brew link --overwrite node@22 2>/dev/null || true
fi

# --- Docker -----------------------------------------------------------------

info "Docker"
step="docker"

if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    skip "Docker ($(docker --version))"
elif command -v docker &>/dev/null; then
    echo "  Docker CLI found but daemon not running."
    echo "  Start Docker Desktop or Colima, then re-run this script."
    exit 1
else
    echo ""
    echo "  Docker is not installed. Choose an option:"
    echo "    1. Docker Desktop (GUI, easy setup, free for personal use)"
    echo "    2. Colima (CLI-only, lightweight, free)"
    echo ""
    if [[ -t 0 ]]; then
        read -rp "  Choose [1/2]: " docker_choice
    else
        docker_choice="1"
    fi

    case "$docker_choice" in
        2)
            brew install colima docker docker-compose
            colima start --cpu 2 --memory 4 --disk 60
            ok "Colima + Docker installed and started"
            ;;
        *)
            brew install --cask docker
            echo ""
            echo "  Docker Desktop installed. Please open it from Applications and complete setup."
            echo "  Once Docker Desktop is running, re-run this script."
            exit 0
            ;;
    esac
fi

# Ensure docker compose plugin works
if ! docker compose version &>/dev/null 2>&1; then
    step="docker compose"
    brew install docker-compose
    ok "Docker Compose installed"
else
    skip "Docker Compose"
fi

# --- Claude Code ------------------------------------------------------------

info "Claude Code"
step="claude code install"

if ! command -v claude &>/dev/null; then
    curl -fsSL https://claude.ai/install.sh | bash
    ok "Claude Code installed"
else
    skip "Claude Code"
fi

# --- Clone / update repo ----------------------------------------------------

info "Repository"
step="git clone/pull"

DEV_ENV="$HOME/dev-env"

if [[ -d "$DEV_ENV/.git" ]]; then
    git -C "$DEV_ENV" pull --ff-only || true
    ok "Updated existing clone"
elif [[ -d "$DEV_ENV" ]]; then
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

# Critical: must exist as a FILE before compose up
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

# Status line script
if [[ -f "$DEV_ENV/scripts/runtime/statusline-command.sh" ]]; then
    cp "$DEV_ENV/scripts/runtime/statusline-command.sh" ~/.claude/statusline-command.sh
    chmod +x ~/.claude/statusline-command.sh
    ok "Installed statusline-command.sh"

    desired='{"permissions":{"defaultMode":"bypassPermissions"},"statusLine":{"type":"command","command":"bash /home/dev/.claude/statusline-command.sh"}}'

    if [[ -f ~/.claude/settings.json ]]; then
        jq --argjson desired "$desired" '$desired * .' \
            ~/.claude/settings.json > ~/.claude/settings.json.tmp \
            && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
        ok "Merged default settings into settings.json"
    else
        echo "$desired" | jq . > ~/.claude/settings.json
        ok "Created settings.json with default settings"
    fi
fi

# tmux config
if [[ -f "$DEV_ENV/scripts/runtime/tmux.conf" ]]; then
    cp "$DEV_ENV/scripts/runtime/tmux.conf" ~/.tmux.conf
    ok "Installed ~/.tmux.conf"
fi

if [[ -f "$DEV_ENV/scripts/runtime/tmux-status.sh" ]]; then
    cp "$DEV_ENV/scripts/runtime/tmux-status.sh" ~/.tmux-status.sh
    chmod +x ~/.tmux-status.sh
    ok "Installed ~/.tmux-status.sh"
fi

tmux source-file ~/.tmux.conf 2>/dev/null && ok "Reloaded tmux config" || true

# --- SSH server (Remote Login) ---------------------------------------------

info "SSH server (Remote Login)"
step="ssh config"

# Check if Remote Login is enabled
if systemsetup -getremotelogin 2>/dev/null | grep -qi "on"; then
    ok "Remote Login is enabled"
else
    echo ""
    echo "  Remote Login (SSH) is not enabled."
    echo "  To enable: System Settings > General > Sharing > Remote Login > toggle ON"
    echo ""
    echo "  After enabling, re-run this script or continue manually."
    echo ""
fi

# Add AcceptEnv NO_CLAUDE to sshd_config if not present
if ! grep -q 'AcceptEnv NO_CLAUDE' /etc/ssh/sshd_config 2>/dev/null; then
    echo ""
    echo "  Adding 'AcceptEnv NO_CLAUDE' to /etc/ssh/sshd_config requires sudo."
    if sudo grep -q 'AcceptEnv' /etc/ssh/sshd_config 2>/dev/null; then
        # Append to existing AcceptEnv line
        sudo sed -i '' 's/^AcceptEnv.*/& NO_CLAUDE/' /etc/ssh/sshd_config
    else
        echo 'AcceptEnv NO_CLAUDE' | sudo tee -a /etc/ssh/sshd_config > /dev/null
    fi
    ok "Added AcceptEnv NO_CLAUDE to sshd_config"
else
    skip "AcceptEnv NO_CLAUDE already configured"
fi

# --- Shell integration (.zprofile) ------------------------------------------

info "Shell integration"
step="zprofile setup"

ZPROFILE="$HOME/.zprofile"

# Homebrew PATH (needed for non-interactive shells)
if ! grep -q 'homebrew' "$ZPROFILE" 2>/dev/null; then
    {
        echo ""
        echo "# Homebrew"
        if [[ -f /opt/homebrew/bin/brew ]]; then
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"'
        else
            echo 'eval "$(/usr/local/bin/brew shellenv)"'
        fi
    } >> "$ZPROFILE"
    ok "Added Homebrew to .zprofile"
else
    skip "Homebrew already in .zprofile"
fi

# Claude Code PATH
if ! grep -q '\.local/bin' "$ZPROFILE" 2>/dev/null; then
    {
        echo ""
        echo '# Claude Code'
        echo 'export PATH="$HOME/.local/bin:$PATH"'
    } >> "$ZPROFILE"
    ok "Added ~/.local/bin to PATH in .zprofile"
else
    # shellcheck disable=SC2088
    skip "~/.local/bin already in .zprofile"
fi

# ssh-login.sh integration
if ! grep -q "ssh-login.sh" "$ZPROFILE" 2>/dev/null; then
    {
        echo ""
        echo "# Auto-launch Claude Code on SSH login"
        echo "source ~/dev-env/scripts/runtime/ssh-login.sh"
    } >> "$ZPROFILE"
    ok "Added ssh-login.sh to .zprofile"
else
    skip "ssh-login.sh already in .zprofile"
fi

# --- Launchd agents ---------------------------------------------------------

info "Launchd agents"
step="launchd setup"

bash "$DEV_ENV/scripts/deploy/install-updater-mac.sh"
bash "$DEV_ENV/scripts/deploy/autostart-mac.sh"

# --- Make scripts executable ------------------------------------------------

step="chmod scripts"
chmod +x "$DEV_ENV"/scripts/deploy/*.sh "$DEV_ENV"/scripts/runtime/*.sh 2>/dev/null || true

# --- Docker pull + start ----------------------------------------------------

info "Docker container"
step="docker pull and up"

if [[ "$LOCAL_BUILD" == "1" ]]; then
    echo "  LOCAL_BUILD=1 — building image locally..."
    (cd "$DEV_ENV" && docker compose -f docker-compose.yml -f docker-compose.mac.yml -f docker-compose.build.yml build)
    ok "Image built locally"
else
    step="docker pull"
    if docker pull "$IMAGE"; then
        ok "Pulled $IMAGE"
    else
        echo "  WARN: Pull failed — falling back to local build..."
        (cd "$DEV_ENV" && docker compose -f docker-compose.yml -f docker-compose.mac.yml -f docker-compose.build.yml build)
        ok "Image built locally (fallback)"
    fi
fi

(cd "$DEV_ENV" && docker compose -f docker-compose.yml -f docker-compose.mac.yml up -d)
ok "Container running"

# Fix container permissions (volumes mount as root)
step="fix container permissions"
(cd "$DEV_ENV" && docker compose -f docker-compose.yml -f docker-compose.mac.yml exec -T -u root dev bash -c \
    "chown dev:dev /home/dev/projects /home/dev/.claude") 2>/dev/null || true
ok "Fixed container permissions"

echo ""
echo "============================================"
echo "  Phase 1 complete! Container is running."
echo "============================================"

# Mark this host as provisioned
cat > "$DEV_ENV/.provisioned" <<EOF
provisioned=$(date -u +%Y-%m-%dT%H:%M:%SZ)
commit=$(git -C "$DEV_ENV" rev-parse --short HEAD 2>/dev/null || echo "unknown")
type=local-mac
EOF
ok "Wrote provisioned marker"

# Write workspace env file
cat > "$DEV_ENV/.env.workspace" <<EOF
# Provisioned $(date +%Y-%m-%d)
WORKSPACE_TYPE=local-mac
HOSTNAME=$(hostname -s)
DEV_ENV=$DEV_ENV
EOF
ok "Wrote .env.workspace"

if [[ "$NON_INTERACTIVE" == "1" ]]; then
    echo ""
    echo "  NON_INTERACTIVE mode — skipping auth setup."
    echo "  Run setup-auth.sh manually inside the container."
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

(cd "$DEV_ENV" && docker compose -f docker-compose.yml -f docker-compose.mac.yml exec -it dev \
    bash /home/dev/dev-env/scripts/deploy/setup-auth.sh) </dev/tty

# --- Energy settings warning ------------------------------------------------

echo ""
echo "  IMPORTANT: For always-on use, prevent your Mac from sleeping:"
echo "    System Settings > Energy Saver (or Battery > Options)"
echo "    - Disable 'Put hard disks to sleep when possible'"
echo "    - Set 'Turn display off after' to your preference"
echo "    - Enable 'Prevent automatic sleeping when the display is off'"
echo ""

# --- Final verification -----------------------------------------------------

info "Verification"
step="verification"

echo ""

if docker ps --format '{{.Names}}' | grep -q "claude-dev"; then
    ok "Container 'claude-dev' is running"
else
    echo "  WARN: Container not running"
fi

echo ""
echo "============================================"
echo "  Setup complete!"
echo "============================================"
echo ""
echo "  Your Mac is now an always-on Claude Code server."
echo ""
echo "  From this Mac:"
echo "    Start working:  bash ~/dev-env/scripts/runtime/start-claude.sh"
echo ""
echo "  From other devices (SSH must be enabled):"
echo "    ssh $USER@$(hostname -s)"
echo ""
echo "  Optional: Run /tailscale for private access from anywhere."
echo ""
