#!/bin/bash
# schedule-v2-recover.sh — Recover missed local-time slots for v2 jobs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/schedule-v2-lib.sh"

recovery_log="$SCHEDULE_V2_LOGS_DIR/recovery.log"

main() {
    local job_id slot slot_file

    schedule_v2_ensure_dirs

    {
        echo "=== $(schedule_v2_now_local) recovery starting ==="
        schedule_v2_write_health running
        /bin/bash "$SCRIPT_DIR/process-schedule-v2-requests.sh" || true
        for job_id in $(schedule_v2_list_job_ids); do
            schedule_v2_load_job "$job_id"
            [[ "$SCHEDULE_V2_JOB_ENABLED" == "true" ]] || continue

            slot="$(schedule_v2_compute_slot "$SCHEDULE_V2_JOB_FILE")"
            slot_file="$(schedule_v2_slot_path "$job_id" "$slot")"

            if schedule_v2_slot_terminal "$job_id" "$slot" || schedule_v2_slot_running "$job_id" "$slot"; then
                echo "skip $job_id: slot $slot already accounted for"
                continue
            fi

            if schedule_v2_slot_within_grace "$SCHEDULE_V2_JOB_FILE" "$slot"; then
                echo "catchup $job_id: slot $slot"
                "$SCRIPT_DIR/schedule-v2-runner.sh" --job-id "$job_id" --slot "$slot" --mode catchup || true
            else
                echo "missed $job_id: slot $slot outside grace"
                schedule_v2_mark_slot_missed "$job_id" "$slot" "catchup" "outside grace window"
            fi
        done
        schedule_v2_write_health idle
        echo "=== $(schedule_v2_now_local) recovery done ==="
    } >> "$recovery_log" 2>&1
}

main "$@"
