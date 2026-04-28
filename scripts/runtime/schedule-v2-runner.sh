#!/bin/bash
# schedule-v2-runner.sh — Execute one v2 scheduled slot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/schedule-v2-lib.sh"

usage() {
    cat <<'EOF'
Usage:
  schedule-v2-runner.sh --job-id <id> --slot <slot-key> --mode <scheduled|catchup>
EOF
}

main() {
    local job_id="" slot="" mode=""
    local log_file started_at rc=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --job-id)
                job_id="${2:-}"
                shift 2
                ;;
            --slot)
                slot="${2:-}"
                shift 2
                ;;
            --mode)
                mode="${2:-}"
                shift 2
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
    done

    [[ -n "$job_id" && -n "$slot" && -n "$mode" ]] || schedule_v2_die "job-id, slot, and mode are required"
    [[ "$mode" == "scheduled" || "$mode" == "catchup" ]] || schedule_v2_die "mode must be scheduled or catchup"

    schedule_v2_ensure_dirs
    schedule_v2_load_job "$job_id"

    [[ "$SCHEDULE_V2_JOB_ENABLED" == "true" ]] || schedule_v2_die "job is disabled: $job_id"

    if schedule_v2_slot_terminal "$job_id" "$slot"; then
        echo "slot already completed: $job_id $slot"
        return 0
    fi
    if schedule_v2_slot_running "$job_id" "$slot"; then
        echo "slot already running: $job_id $slot"
        return 0
    fi
    if ! schedule_v2_acquire_lock "$job_id"; then
        echo "job already locked: $job_id"
        return 0
    fi
    trap 'schedule_v2_release_lock "$job_id"' EXIT

    started_at="$(schedule_v2_now_local)"
    log_file="$(schedule_v2_job_log_path "$job_id")"
    export SCHEDULE_V2_RUN_SLOT="$slot"
    export SCHEDULE_V2_RUN_SLOT_DATE="${slot%%T*}"
    export SCHEDULE_V2_RUN_MODE="$mode"

    schedule_v2_write_slot_ledger "$job_id" "$slot" "$mode" "running" "" "" "$started_at" ""
    schedule_v2_write_status "$job_id" "$slot" "running" "$mode"

    {
        echo "=== $(schedule_v2_now_local) job $job_id slot $slot mode $mode starting ==="
        echo "cwd: $SCHEDULE_V2_JOB_CWD"
        echo "command: $SCHEDULE_V2_JOB_COMMAND"

        set +e
        schedule_v2_run_container_command
        rc=$?
        set -e

        if [[ "$rc" -eq 0 ]]; then
            echo "=== $(schedule_v2_now_local) job $job_id slot $slot succeeded ==="
            schedule_v2_write_slot_ledger "$job_id" "$slot" "$mode" "succeeded" "$rc" "" "$started_at" "$(schedule_v2_now_local)"
            schedule_v2_write_status "$job_id" "$slot" "scheduled" "$mode" "succeeded" "$rc"
        else
            echo "=== $(schedule_v2_now_local) job $job_id slot $slot failed: exit $rc ==="
            schedule_v2_write_slot_ledger "$job_id" "$slot" "$mode" "failed" "$rc" "" "$started_at" "$(schedule_v2_now_local)"
            schedule_v2_write_status "$job_id" "$slot" "scheduled" "$mode" "failed" "$rc"
        fi

        exit "$rc"
    } >> "$log_file" 2>&1
}

main "$@"
