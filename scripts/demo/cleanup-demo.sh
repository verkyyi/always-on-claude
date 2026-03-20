#!/bin/bash
# cleanup-demo.sh — Remove expired demo users from host and container.
#
# Designed to run as a cron job (every 15 minutes).
# Finds demo-* users whose .demo-expires timestamp has passed,
# kills their processes, and removes them from both host and container.
#
# Usage:
#   sudo bash scripts/demo/cleanup-demo.sh
#
# Cron (installed by install-demo.sh):
#   */15 * * * * /path/to/cleanup-demo.sh >> /var/log/demo-cleanup.log 2>&1

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-claude-dev}"
DEMO_PREFIX="demo-"
NOW_EPOCH=$(date -u +%s)

# --- Helpers ----------------------------------------------------------------

info()  { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# --- Find and remove expired demo users -------------------------------------

expired_count=0
active_count=0

while IFS=: read -r username _ _ _ _ homedir _; do
    # Only process demo-* users
    [[ "$username" == ${DEMO_PREFIX}* ]] || continue

    expiry_file="$homedir/.demo-expires"

    # If no expiry file, treat as expired (safety)
    if [[ ! -f "$expiry_file" ]]; then
        info "WARN: $username has no .demo-expires file — removing"
    else
        expiry_ts=$(cat "$expiry_file")
        expiry_epoch=$(date -d "$expiry_ts" +%s 2>/dev/null || echo 0)

        if [[ $expiry_epoch -gt $NOW_EPOCH ]]; then
            ((active_count++))
            continue
        fi
    fi

    # --- User is expired — remove them ---

    info "Removing expired demo user: $username"
    ((expired_count++))

    # Kill all host processes for this user
    pkill -u "$username" 2>/dev/null || true
    sleep 1
    pkill -9 -u "$username" 2>/dev/null || true

    # Remove container user and their home directory
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        docker exec "$CONTAINER_NAME" bash -c "
            pkill -u '$username' 2>/dev/null || true
            sleep 1
            pkill -9 -u '$username' 2>/dev/null || true
            userdel -r '$username' 2>/dev/null || true
        " 2>/dev/null || true
    fi

    # Remove host user and their home directory
    userdel -r "$username" 2>/dev/null || true

    info "  Removed: $username"

done < /etc/passwd

if [[ $expired_count -gt 0 || $active_count -gt 0 ]]; then
    info "Summary: removed $expired_count expired, $active_count still active"
fi
