#!/bin/bash
# install-demo.sh — Configure a host as a shared demo server.
#
# Run on an existing always-on-claude instance (after install.sh).
# Sets up cron for cleanup, hardens isolation, and configures
# the container for multi-user demo access.
#
# Usage:
#   sudo bash scripts/demo/install-demo.sh
#
# Idempotent — safe to re-run.

set -euo pipefail

# --- Helpers ----------------------------------------------------------------

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
skip()  { echo "  SKIP: $* (already done)"; }
die()   { echo "ERROR: $*" >&2; exit 1; }

# Wrap sudo: no-op when already root
if [[ $EUID -eq 0 ]]; then
    sudo() { "$@"; }
fi

# --- Preflight --------------------------------------------------------------

info "Preflight checks"

[[ $EUID -eq 0 ]] || die "Must run as root (use sudo)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

if ! docker ps --format '{{.Names}}' | grep -q "^claude-dev$"; then
    die "Container 'claude-dev' is not running. Run install.sh first."
fi

ok "Container running, repo at $REPO_DIR"

# --- Cron job for cleanup ---------------------------------------------------

info "Cleanup cron job"

CRON_LINE="*/15 * * * * /bin/bash $SCRIPT_DIR/cleanup-demo.sh >> /var/log/demo-cleanup.log 2>&1"

if crontab -l 2>/dev/null | grep -q "cleanup-demo.sh"; then
    skip "Cleanup cron already installed"
else
    (crontab -l 2>/dev/null || true; echo "$CRON_LINE") | crontab -
    ok "Installed cron: runs every 15 minutes"
fi

# --- Process isolation (hidepid) --------------------------------------------

info "Process isolation"

if mount | grep -q "hidepid=2"; then
    skip "hidepid=2 already set on /proc"
else
    mount -o remount,hidepid=2 /proc 2>/dev/null || true
    # Make it persistent across reboots
    if ! grep -q "hidepid=2" /etc/fstab 2>/dev/null; then
        echo "proc /proc proc defaults,hidepid=2 0 0" >> /etc/fstab
    fi
    ok "Set hidepid=2 on /proc (users can only see their own processes)"
fi

# --- SSH hardening ----------------------------------------------------------

info "SSH hardening for demo"

SSHD_DEMO="/etc/ssh/sshd_config.d/demo.conf"

if [[ -f "$SSHD_DEMO" ]]; then
    skip "Demo SSH config already exists"
else
    cat > "$SSHD_DEMO" << 'SSHD'
# Demo user restrictions
Match Group demo
    X11Forwarding no
    AllowTcpForwarding no
    PermitTunnel no
    ForceCommand docker exec -it -u $USER claude-dev bash -l
SSHD
    # Create demo group if it doesn't exist
    groupadd -f demo
    systemctl reload ssh 2>/dev/null || true
    ok "SSH hardening configured (demo group restricted)"
fi

# --- Mark scripts executable ------------------------------------------------

info "Scripts"

chmod +x "$SCRIPT_DIR/create-demo.sh"
chmod +x "$SCRIPT_DIR/cleanup-demo.sh"
ok "Demo scripts marked executable"

# --- Write demo marker ------------------------------------------------------

cat > "$REPO_DIR/.env.demo" << EOF
# Demo server configured $(date -u +%Y-%m-%dT%H:%M:%SZ)
DEMO_SERVER=true
DEMO_TTL=7200
EOF

ok "Wrote .env.demo marker"

# --- Done -------------------------------------------------------------------

echo ""
echo "============================================"
echo "  Demo server configured!"
echo "============================================"
echo ""
echo "  Create demo accounts:"
echo "    sudo bash $SCRIPT_DIR/create-demo.sh"
echo ""
echo "  Custom TTL (1 hour):"
echo "    sudo DEMO_TTL=3600 bash $SCRIPT_DIR/create-demo.sh"
echo ""
echo "  Check active demo users:"
echo "    grep '^demo-' /etc/passwd"
echo ""
echo "  Manual cleanup:"
echo "    sudo bash $SCRIPT_DIR/cleanup-demo.sh"
echo ""
echo "  Cleanup runs automatically every 15 minutes via cron."
echo ""
