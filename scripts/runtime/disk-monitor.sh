#!/bin/bash
# disk-monitor.sh — Monitor disk usage and warn before hitting capacity.
#
# Checks disk usage on /, warns at configurable thresholds, and optionally
# runs cleanup actions. Designed to be called by systemd timer or cron.
#
# Exit codes:
#   0 — OK, below all thresholds
#   1 — Warning threshold exceeded
#   2 — Critical threshold exceeded

set -euo pipefail

# --- Config (override with env vars) ----------------------------------------

WARN_THRESHOLD="${DISK_WARN_THRESHOLD:-80}"
CRITICAL_THRESHOLD="${DISK_CRITICAL_THRESHOLD:-90}"
MOUNT_POINT="${DISK_MOUNT_POINT:-/}"
LOG_FILE="${DISK_LOG_FILE:-/var/log/disk-monitor.log}"
USERS_CONF="${USERS_CONF:-/home/dev/users/.users.conf}"

# --- Helpers ----------------------------------------------------------------

timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log_msg() {
    local level="$1" msg="$2"
    echo "$(timestamp) [$level] $msg" | tee -a "$LOG_FILE" 2>/dev/null || echo "$(timestamp) [$level] $msg"
}

# --- Check disk usage -------------------------------------------------------

usage_pct=$(df "$MOUNT_POINT" --output=pcent 2>/dev/null | tail -1 | tr -d ' %' || echo "0")
usage_human=$(df -h "$MOUNT_POINT" --output=used,size,avail 2>/dev/null | tail -1 | xargs || echo "unknown")

# --- Per-user disk usage (if multi-user) ------------------------------------

report_per_user() {
    if [[ ! -f "$USERS_CONF" ]]; then
        return
    fi

    log_msg "INFO" "Per-user disk usage:"
    while IFS='|' read -r username _ _; do
        [[ -z "$username" || "$username" == "#"* ]] && continue
        local user_dir="/home/dev/users/$username"
        if [[ -d "$user_dir" ]]; then
            local user_usage
            user_usage=$(du -sh "$user_dir" 2>/dev/null | cut -f1 || echo "unknown")
            log_msg "INFO" "  $username: $user_usage"
        fi
    done < "$USERS_CONF"

    # Also report the default dev user
    if [[ -d /home/dev/projects ]]; then
        local dev_usage
        dev_usage=$(du -sh /home/dev/projects 2>/dev/null | cut -f1 || echo "unknown")
        log_msg "INFO" "  dev (default): $dev_usage"
    fi
}

# --- Docker cleanup (safe — only removes unused resources) ------------------

docker_cleanup() {
    log_msg "INFO" "Running Docker cleanup..."
    # Only prune images and build cache — never touch containers.
    # docker system prune -f would remove other users' stopped containers.
    docker image prune -f 2>/dev/null | tail -1 | while read -r line; do
        log_msg "INFO" "Image cleanup: $line"
    done
    docker builder prune -f 2>/dev/null | tail -1 | while read -r line; do
        log_msg "INFO" "Builder cleanup: $line"
    done
}

# --- Evaluate thresholds ----------------------------------------------------

if [[ "$usage_pct" -ge "$CRITICAL_THRESHOLD" ]]; then
    log_msg "CRITICAL" "Disk usage at ${usage_pct}% ($usage_human) on $MOUNT_POINT — threshold: ${CRITICAL_THRESHOLD}%"
    report_per_user

    # Attempt automatic cleanup at critical level
    docker_cleanup

    # Re-check after cleanup
    usage_pct_after=$(df "$MOUNT_POINT" --output=pcent 2>/dev/null | tail -1 | tr -d ' %' || echo "0")
    if [[ "$usage_pct_after" -ge "$CRITICAL_THRESHOLD" ]]; then
        log_msg "CRITICAL" "Still at ${usage_pct_after}% after cleanup — manual intervention needed"

        # Write warning file for SSH login display (root-owned, not world-writable)
        echo "CRITICAL: Disk usage at ${usage_pct_after}% — free space immediately" > /run/disk-monitor.warning
        chmod 644 /run/disk-monitor.warning
    else
        log_msg "INFO" "Cleaned up to ${usage_pct_after}%"
        rm -f /run/disk-monitor.warning
    fi
    exit 2

elif [[ "$usage_pct" -ge "$WARN_THRESHOLD" ]]; then
    log_msg "WARN" "Disk usage at ${usage_pct}% ($usage_human) on $MOUNT_POINT — threshold: ${WARN_THRESHOLD}%"
    report_per_user

    echo "WARNING: Disk usage at ${usage_pct}% — consider freeing space" > /run/disk-monitor.warning
    chmod 644 /run/disk-monitor.warning
    exit 1

else
    log_msg "INFO" "Disk usage OK: ${usage_pct}% ($usage_human) on $MOUNT_POINT"
    rm -f /run/disk-monitor.warning
    exit 0
fi
