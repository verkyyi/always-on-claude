#!/bin/bash
# create-demo.sh — Create a temporary demo user on a shared demo server.
#
# Creates a host user (for SSH) and a container user (for Claude Code),
# generates an SSH key pair, and sets an expiry timestamp.
#
# Usage:
#   sudo bash scripts/demo/create-demo.sh
#   sudo DEMO_TTL=3600 bash scripts/demo/create-demo.sh   # 1-hour demo
#
# Output: prints the SSH private key and connection command.
# The demo user can then `claude login` with their own subscription.

set -euo pipefail

# --- Config -----------------------------------------------------------------

DEMO_TTL="${DEMO_TTL:-7200}"  # seconds until expiry (default: 2 hours)
CONTAINER_NAME="${CONTAINER_NAME:-claude-dev}"
DEMO_PREFIX="demo"

# --- Helpers ----------------------------------------------------------------

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
die()   { echo "ERROR: $*" >&2; exit 1; }

# --- Preflight --------------------------------------------------------------

[[ $EUID -eq 0 ]] || die "Must run as root (use sudo)"

# Verify container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    die "Container '$CONTAINER_NAME' is not running. Start it first."
fi

# --- Generate unique username -----------------------------------------------

info "Creating demo user"

# 4-char random suffix (lowercase alphanumeric)
SUFFIX=$(head -c 32 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 4)
USERNAME="${DEMO_PREFIX}-${SUFFIX}"

# Ensure uniqueness
while id "$USERNAME" &>/dev/null 2>&1; do
    SUFFIX=$(head -c 32 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 4)
    USERNAME="${DEMO_PREFIX}-${SUFFIX}"
done

ok "Username: $USERNAME"

# --- Create host user (for SSH access) --------------------------------------

info "Host user"

useradd -m -s /bin/bash "$USERNAME"
chmod 700 "/home/$USERNAME"

# Add to demo group (created by install-demo.sh) for SSH restrictions
if getent group demo &>/dev/null; then
    usermod -aG demo "$USERNAME"
fi

ok "Created host user $USERNAME"

# --- Generate SSH key pair --------------------------------------------------

info "SSH key"

SSH_DIR="/home/$USERNAME/.ssh"
mkdir -p "$SSH_DIR"

ssh-keygen -t ed25519 -f "$SSH_DIR/demo_key" -N "" -C "$USERNAME@demo" -q

# Authorize the public key for SSH login
cp "$SSH_DIR/demo_key.pub" "$SSH_DIR/authorized_keys"
chmod 600 "$SSH_DIR/authorized_keys"
chmod 700 "$SSH_DIR"
chown -R "$USERNAME:$USERNAME" "$SSH_DIR"

# Save the private key contents for output
PRIVATE_KEY=$(cat "$SSH_DIR/demo_key")

ok "SSH key generated"

# --- Create container user --------------------------------------------------

info "Container user"

docker exec "$CONTAINER_NAME" bash -c "
    useradd -m -s /bin/bash '$USERNAME' 2>/dev/null || true
    chmod 700 '/home/$USERNAME'

    # Pre-create Claude Code directories (same as Dockerfile)
    mkdir -p '/home/$USERNAME/.claude/debug'
    touch '/home/$USERNAME/.claude/remote-settings.json'

    # Create .claude.json for onboarding state
    echo '{}' > '/home/$USERNAME/.claude.json'

    # Fix ownership
    chown -R '$USERNAME:$USERNAME' '/home/$USERNAME'
"

ok "Created container user $USERNAME"

# --- Set expiry timestamp ---------------------------------------------------

info "Expiry"

EXPIRES_AT=$(date -d "+${DEMO_TTL} seconds" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -v "+${DEMO_TTL}S" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)

# Write expiry to both host and container home dirs
echo "$EXPIRES_AT" > "/home/$USERNAME/.demo-expires"
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.demo-expires"

docker exec "$CONTAINER_NAME" bash -c "
    echo '$EXPIRES_AT' > '/home/$USERNAME/.demo-expires'
    chown '$USERNAME:$USERNAME' '/home/$USERNAME/.demo-expires'
"

EXPIRES_HUMAN=$(date -d "+${DEMO_TTL} seconds" '+%Y-%m-%d %H:%M %Z' 2>/dev/null \
    || date -v "+${DEMO_TTL}S" '+%Y-%m-%d %H:%M %Z' 2>/dev/null)

ok "Expires at $EXPIRES_HUMAN ($((DEMO_TTL / 60)) minutes from now)"

# --- Set up host .bash_profile to auto-enter container ----------------------

info "Shell integration"

cat > "/home/$USERNAME/.bash_profile" << 'PROFILE'
# Demo user — auto-enter container on SSH login
[[ $- != *i* ]] && return
[[ -n "${TMUX:-}" ]] && return

CONTAINER_NAME="claude-dev"
USERNAME="$(whoami)"

echo ""
echo "  Welcome to the always-on-claude demo!"
echo ""
echo "  Your demo session expires at: $(cat ~/.demo-expires 2>/dev/null || echo 'unknown')"
echo ""
echo "  What you can do:"
echo "    - Run 'claude login' to authenticate with your own Claude subscription"
echo "    - Explore the workspace, tmux sessions, and dev tools"
echo "    - Clone repos into ~/projects and use Claude Code"
echo ""
echo "  This is a shared demo server. Your home directory is private."
echo "  Files will be deleted when your session expires."
echo ""

exec docker exec -it -u "$USERNAME" "$CONTAINER_NAME" bash -l
PROFILE

chown "$USERNAME:$USERNAME" "/home/$USERNAME/.bash_profile"

ok "Shell integration configured"

# --- Output -----------------------------------------------------------------

# Get the host's public IP or hostname for the SSH command
HOST_IP=$(curl -sf http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null \
    || hostname -I 2>/dev/null | awk '{print $1}' \
    || hostname)

echo ""
echo "============================================"
echo "  Demo account created!"
echo "============================================"
echo ""
echo "  Username:  $USERNAME"
echo "  Expires:   $EXPIRES_HUMAN"
echo "  Host:      $HOST_IP"
echo ""
echo "  --- Send this to the user ---"
echo ""
echo "  Connect:"
echo "    1. Save the key below to a file (e.g. demo.pem)"
echo "    2. chmod 600 demo.pem"
echo "    3. ssh -i demo.pem ${USERNAME}@${HOST_IP}"
echo ""
echo "  SSH Private Key:"
echo "  ────────────────"
echo "$PRIVATE_KEY"
echo "  ────────────────"
echo ""
echo "  Once connected, run 'claude login' to use your own Claude subscription."
echo ""
