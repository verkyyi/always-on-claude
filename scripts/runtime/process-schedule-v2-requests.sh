#!/bin/bash
# process-schedule-v2-requests.sh — Apply container-submitted v2 schedule requests on the host.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/schedule-v2-lib.sh"

MANAGE_SCRIPT="${AOC_SCHEDULE_V2_MANAGE:-$SCRIPT_DIR/schedule-v2-manage.sh}"

schedule_v2_ensure_dirs

request_status_tmp() {
    mktemp "$SCHEDULE_V2_REQUEST_STATUS_DIR/.request.tmp.XXXXXX"
}

write_request_status() {
    local request_id="$1"
    local state="$2"
    local action="$3"
    local job_id="${4:-}"
    local reason="${5:-}"
    local tmp

    tmp="$(request_status_tmp)"
    jq -n \
        --arg version "2" \
        --arg request_id "$request_id" \
        --arg action "$action" \
        --arg job_id "$job_id" \
        --arg status "$state" \
        --arg reason "$reason" \
        --arg updated_at "$(schedule_v2_now_local)" \
        '{
            version: ($version | tonumber),
            request_id: $request_id,
            action: $action,
            job_id: (if ($job_id | length) > 0 then $job_id else null end),
            status: $status,
            reason: (if ($reason | length) > 0 then $reason else null end),
            updated_at: $updated_at
        }' > "$tmp"
    mv "$tmp" "$(schedule_v2_request_status_path "$request_id")"
}

valid_job_id() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

validate_job_payload() {
    local request_file="$1"

    jq -e '
        .version == 2 and
        (.action == "create" or .action == "update") and
        (.job | type == "object") and
        (.job.id | type == "string" and length > 0) and
        (.job.label | type == "string" or .job.label == null) and
        (.job.timezone | type == "string" and length > 0) and
        (.job.cwd | type == "string" and startswith("/home/dev/projects")) and
        (.job.command | type == "string" and length > 0) and
        (.job.schedule | type == "object") and
        (.job.schedule.type as $type | ["hourly", "daily", "daily_hours", "weekly", "monthly", "once"] | index($type)) != null
    ' "$request_file" >/dev/null
}

validate_timezone() {
    local tz="$1"
    python3 - "$tz" <<'PY'
import sys
from zoneinfo import ZoneInfo

ZoneInfo(sys.argv[1])
PY
}

validate_request_file() {
    local request_file="$1"
    local action

    jq -e '.version == 2 and (.request_id | type == "string" and length > 0) and (.action | type == "string" and length > 0)' "$request_file" >/dev/null \
        || return 1

    action="$(jq -r '.action' "$request_file")"
    case "$action" in
        create|update)
            validate_job_payload "$request_file" || return 1
            valid_job_id "$(jq -r '.job.id' "$request_file")" || return 1
            validate_timezone "$(jq -r '.job.timezone' "$request_file")" >/dev/null 2>&1 || return 1
            ;;
        delete|enable|disable|run-now)
            jq -e '.job_id | type == "string" and length > 0' "$request_file" >/dev/null \
                || return 1
            valid_job_id "$(jq -r '.job_id' "$request_file")" || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

write_job_definition() {
    local request_file="$1"
    local job_id target tmp

    job_id="$(jq -r '.job.id' "$request_file")"
    target="$(schedule_v2_job_def_path "$job_id")"
    tmp="$(mktemp "$SCHEDULE_V2_JOBS_DIR/.job.tmp.XXXXXX")"
    jq '.job' "$request_file" > "$tmp"
    mv "$tmp" "$target"
}

set_job_enabled() {
    local job_id="$1"
    local enabled="$2"
    local target tmp

    target="$(schedule_v2_job_def_path "$job_id")"
    [[ -f "$target" ]] || schedule_v2_die "Job definition not found: $job_id"
    tmp="$(mktemp "$SCHEDULE_V2_JOBS_DIR/.job.tmp.XXXXXX")"
    jq --argjson enabled "$enabled" '.enabled = $enabled' "$target" > "$tmp"
    mv "$tmp" "$target"
}

process_one_request() {
    local request_file="$1"
    local request_id action job_id tmp reason

    request_id="$(jq -r '.request_id' "$request_file")"
    action="$(jq -r '.action' "$request_file")"
    job_id="$(jq -r '.job.id // .job_id // empty' "$request_file")"

    write_request_status "$request_id" "processing" "$action" "$job_id"

    case "$action" in
        create|update)
            write_job_definition "$request_file"
            "$MANAGE_SCRIPT" install-job "$job_id" >/dev/null
            ;;
        delete)
            "$MANAGE_SCRIPT" uninstall-job "$job_id" >/dev/null
            rm -f "$(schedule_v2_job_def_path "$job_id")"
            rm -f "$(schedule_v2_job_status_path "$job_id")"
            ;;
        enable)
            set_job_enabled "$job_id" true
            "$MANAGE_SCRIPT" install-job "$job_id" >/dev/null
            ;;
        disable)
            set_job_enabled "$job_id" false
            "$MANAGE_SCRIPT" uninstall-job "$job_id" >/dev/null
            ;;
        run-now)
            "$SCRIPT_DIR/schedule-v2-run-scheduled.sh" "$job_id" >/dev/null
            ;;
    esac

    write_request_status "$request_id" "succeeded" "$action" "$job_id"
    rm -f "$request_file"
}

main() {
    local request_file request_id action job_id

    shopt -s nullglob
    for request_file in "$SCHEDULE_V2_INBOX_DIR"/*.json; do
        request_id=""
        action=""
        job_id=""
        if ! request_id="$(jq -r '.request_id // empty' "$request_file" 2>/dev/null)"; then
            request_id="$(basename "$request_file" .json)"
        fi
        action="$(jq -r '.action // empty' "$request_file" 2>/dev/null || true)"
        job_id="$(jq -r '.job.id // .job_id // empty' "$request_file" 2>/dev/null || true)"
        if validate_request_file "$request_file"; then
            if ! process_one_request "$request_file"; then
                reason="request processing failed"
                write_request_status "$request_id" "failed" "$action" "$job_id" "$reason"
                rm -f "$request_file"
            fi
        else
            reason="request validation failed"
            write_request_status "$request_id" "failed" "$action" "$job_id" "$reason"
            rm -f "$request_file"
        fi
    done
}

main "$@"
