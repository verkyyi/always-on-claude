#!/bin/bash
# schedule-bridge.sh — Inspect and manage the host schedule bridge.

set -euo pipefail

die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  schedule-bridge.sh status
  schedule-bridge.sh pause [reason...]
  schedule-bridge.sh resume
EOF
}

LABEL="${AOC_SCHEDULE_LABEL:-com.always-on-claude.schedule-bridge}"
SERVICE_NAME="${AOC_SCHEDULE_SERVICE:-always-on-claude-schedule-bridge}"
SCHEDULE_DIR="${AOC_SCHEDULE_DIR:-$HOME/.always-on-claude/schedule}"
PLIST="${AOC_SCHEDULE_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"

pause_marker() {
    local stamp
    stamp="$(date +%Y%m%dT%H%M%S%z)"
    printf '%s/PAUSED.schedule-bridge.%s.txt\n' "$SCHEDULE_DIR" "$stamp"
}

mac_domain() {
    printf 'gui/%s/%s\n' "$(id -u)" "$LABEL"
}

pause_mac() {
    local reason="$1"
    local marker

    mkdir -p "$SCHEDULE_DIR"
    marker="$(pause_marker)"
    {
        printf 'Paused %s at %s\n' "$LABEL" "$(date)"
        printf 'Reason: %s\n' "$reason"
        printf '\nResume commands:\n'
        printf '  launchctl enable %s\n' "$(mac_domain)"
        printf '  launchctl bootstrap gui/%s %s\n' "$(id -u)" "$PLIST"
        printf '  launchctl kickstart -k %s\n' "$(mac_domain)"
    } > "$marker"

    launchctl disable "$(mac_domain)" || true
    launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
    echo "paused"
    echo "$marker"
}

resume_mac() {
    launchctl enable "$(mac_domain)"
    launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
    launchctl kickstart -k "$(mac_domain)" >/dev/null 2>&1 || true
    rm -f "$SCHEDULE_DIR"/PAUSED.schedule-bridge.*.txt
    echo "resumed"
}

status_mac() {
    echo "backend=launchd"
    echo "label=$LABEL"
    launchctl print-disabled "gui/$(id -u)" | grep -F "\"$LABEL\"" || true
    launchctl print "$(mac_domain)" 2>/dev/null | sed -n '1,40p' || echo "state=not-loaded"
    ls -1 "$SCHEDULE_DIR"/PAUSED.schedule-bridge.*.txt 2>/dev/null || true
}

pause_linux() {
    local reason="$1"
    local marker

    mkdir -p "$SCHEDULE_DIR"
    marker="$(pause_marker)"
    {
        printf 'Paused %s at %s\n' "$SERVICE_NAME" "$(date)"
        printf 'Reason: %s\n' "$reason"
    } > "$marker"

    systemctl disable --now "${SERVICE_NAME}.path" >/dev/null 2>&1 || true
    systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
    echo "paused"
    echo "$marker"
}

resume_linux() {
    systemctl enable --now "${SERVICE_NAME}.path" >/dev/null 2>&1
    systemctl restart "${SERVICE_NAME}.path" >/dev/null 2>&1
    rm -f "$SCHEDULE_DIR"/PAUSED.schedule-bridge.*.txt
    echo "resumed"
}

status_linux() {
    echo "backend=systemd"
    echo "service=${SERVICE_NAME}.path"
    systemctl status "${SERVICE_NAME}.path" "${SERVICE_NAME}.service" --no-pager --full || true
    ls -1 "$SCHEDULE_DIR"/PAUSED.schedule-bridge.*.txt 2>/dev/null || true
}

main() {
    local cmd="${1:-status}"
    local reason

    case "$cmd" in
        status|pause|resume)
            ;;
        -h|--help|help)
            usage
            return 0
            ;;
        *)
            usage >&2
            return 1
            ;;
    esac

    if command -v launchctl >/dev/null 2>&1 && [[ -f "$PLIST" ]]; then
        case "$cmd" in
            status) status_mac ;;
            pause)
                shift || true
                reason="${*:-manual pause}"
                pause_mac "$reason"
                ;;
            resume) resume_mac ;;
        esac
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1; then
        case "$cmd" in
            status) status_linux ;;
            pause)
                shift || true
                reason="${*:-manual pause}"
                pause_linux "$reason"
                ;;
            resume) resume_linux ;;
        esac
        return 0
    fi

    die "No supported service manager found"
}

main "$@"
