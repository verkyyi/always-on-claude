#!/bin/bash
# aoc-schedule.sh — Container-facing CLI for the v2 host-native scheduler.

set -euo pipefail

die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  aoc-schedule at <YYYY-MM-DD HH:MM> [options] -- <command>
  aoc-schedule hourly --minute <0-59> [options] -- <command>
  aoc-schedule daily --time <HH:MM> [options] -- <command>
  aoc-schedule weekly --weekday <weekday> --time <HH:MM> [options] -- <command>
  aoc-schedule monthly --day <1-31> --time <HH:MM> [options] -- <command>
  aoc-schedule delete <job-id>
  aoc-schedule enable <job-id>
  aoc-schedule disable <job-id>
  aoc-schedule run-now <job-id>
  aoc-schedule list
  aoc-schedule health
  aoc-schedule status <job-id>
  aoc-schedule logs <job-id> [lines]

Common options:
  --cwd <container-path>     default: current directory
  --label <name>             human-readable label
  --id <job-id>              stable job id; defaults to sanitized label or generated id
  --grace-hours <hours>      default: 2
  --timeout-sec <seconds>    default: 3600
  --timezone <IANA zone>     default: system local timezone

Examples:
  aoc-schedule daily --time 03:00 -- ./scripts/nightly.sh
  aoc-schedule hourly --minute 0 --label dashboard-hourly -- ./dashboard/hourly.sh
  aoc-schedule weekly --weekday friday --time 21:00 -- ./scripts/report.sh
  aoc-schedule at "2026-04-26 09:00" -- ./scripts/one-off.sh
  aoc-schedule status dashboard-hourly
EOF
}

schedule_root() {
    if [[ -n "${AOC_SCHEDULE_DIR:-}" ]]; then
        echo "$AOC_SCHEDULE_DIR"
    elif [[ -d "$HOME/.always-on-claude/schedule" ]]; then
        echo "$HOME/.always-on-claude/schedule"
    elif [[ -d "$HOME/.aoc/schedule" ]]; then
        echo "$HOME/.aoc/schedule"
    else
        echo "$HOME/.always-on-claude/schedule"
    fi
}

ROOT="$(schedule_root)"
INBOX_V2_DIR="$ROOT/inbox-v2"
REQUEST_STATUS_DIR="$ROOT/request-status"
STATUS_DIR="$ROOT/status"
JOBS_DIR="$ROOT/jobs"
LOG_DIR="$ROOT/logs"
HEALTH_FILE="$ROOT/bridge-health.json"

require_jq() {
    command -v jq >/dev/null 2>&1 || die "jq is required"
}

require_inbox() {
    [[ -d "$INBOX_V2_DIR" ]] || die "Schedule v2 inbox not found at $INBOX_V2_DIR. Run /update on the host and restart the container."
    [[ -w "$INBOX_V2_DIR" ]] || die "Schedule v2 inbox is not writable: $INBOX_V2_DIR"
}

random_hex() {
    if command -v od >/dev/null 2>&1; then
        od -An -N4 -tx1 /dev/urandom | tr -d ' \n'
    else
        date +%N
    fi
}

new_id() {
    printf '%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$(random_hex)"
}

valid_id() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

sanitize_id() {
    local value="$1"
    value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-')"
    value="${value#-}"
    value="${value%-}"
    printf '%s\n' "$value"
}

system_timezone() {
    local link

    link="$(readlink /etc/localtime 2>/dev/null || true)"
    if [[ "$link" == *"/zoneinfo/"* ]]; then
        printf '%s\n' "${link##*/zoneinfo/}"
        return 0
    fi

    python3 - <<'PY'
from datetime import datetime
tz = datetime.now().astimezone().tzinfo
print(getattr(tz, "key", None) or str(tz))
PY
}

self_cmd() {
    if [[ -n "${AOC_SCHEDULE_COMMAND:-}" ]]; then
        echo "$AOC_SCHEDULE_COMMAND"
    else
        echo "$0"
    fi
}

container_cwd_ok() {
    [[ "$1" == "/home/dev/projects" || "$1" == /home/dev/projects/* ]]
}

command_from_args() {
    if [[ $# -eq 1 ]]; then
        printf '%s' "$1"
        return 0
    fi

    local out="" arg
    for arg in "$@"; do
        printf -v out '%s%q ' "$out" "$arg"
    done
    printf '%s' "${out% }"
}

write_request() {
    local id="$1"
    local tmp="$INBOX_V2_DIR/.${id}.tmp"
    local dest="$INBOX_V2_DIR/${id}.json"

    umask 077
    cat > "$tmp"
    mv "$tmp" "$dest"
}

resolve_job_id() {
    local explicit_id="$1"
    local label="$2"
    local fallback

    if [[ -n "$explicit_id" ]]; then
        valid_id "$explicit_id" || die "Invalid job id: $explicit_id"
        printf '%s\n' "$explicit_id"
        return 0
    fi

    if [[ -n "$label" ]]; then
        fallback="$(sanitize_id "$label")"
        [[ -n "$fallback" ]] || die "Could not derive job id from label: $label"
        valid_id "$fallback" || die "Derived invalid job id: $fallback"
        printf '%s\n' "$fallback"
        return 0
    fi

    new_id
}

parse_hhmm() {
    local value="$1"
    [[ "$value" =~ ^([0-9]{2}):([0-9]{2})$ ]] || die "Time must be HH:MM: $value"
    local hour="${BASH_REMATCH[1]}"
    local minute="${BASH_REMATCH[2]}"
    ((10#$hour >= 0 && 10#$hour <= 23)) || die "Hour out of range: $value"
    ((10#$minute >= 0 && 10#$minute <= 59)) || die "Minute out of range: $value"
    printf '%s %s\n' "$((10#$hour))" "$((10#$minute))"
}

normalize_weekday() {
    case "${1,,}" in
        mon|monday) echo monday ;;
        tue|tues|tuesday) echo tuesday ;;
        wed|wednesday) echo wednesday ;;
        thu|thur|thurs|thursday) echo thursday ;;
        fri|friday) echo friday ;;
        sat|saturday) echo saturday ;;
        sun|sunday) echo sunday ;;
        *) die "Unsupported weekday: $1" ;;
    esac
}

schedule_display() {
    local job_file="$1"
    python3 - "$job_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    job = json.load(fh)

s = job["schedule"]
kind = s["type"]
if kind == "hourly":
    print(f"hourly @ :{int(s['minute']):02d}")
elif kind == "daily":
    print(f"daily @ {int(s['hour']):02d}:{int(s['minute']):02d}")
elif kind == "weekly":
    print(f"weekly {s['weekday']} {int(s['hour']):02d}:{int(s['minute']):02d}")
elif kind == "monthly":
    print(f"monthly day {int(s['day'])} {int(s['hour']):02d}:{int(s['minute']):02d}")
elif kind == "once":
    print(f"once @ {s['local_time']}")
else:
    print(kind)
PY
}

create_request() {
    local action="$1"
    local job_json="${2:-}"
    local job_id="${3:-}"
    local request_id created_at requested_by self

    request_id="$(new_id)"
    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    requested_by="$(whoami 2>/dev/null || echo dev)"
    self="$(self_cmd)"

    if [[ -n "$job_json" ]]; then
        jq -n \
            --arg request_id "$request_id" \
            --arg action "$action" \
            --arg created_at "$created_at" \
            --arg requested_by "$requested_by" \
            --argjson job "$job_json" \
            '{
                version: 2,
                request_id: $request_id,
                action: $action,
                created_at: $created_at,
                requested_by: $requested_by,
                job: $job
            }' | write_request "$request_id"
    else
        jq -n \
            --arg request_id "$request_id" \
            --arg action "$action" \
            --arg created_at "$created_at" \
            --arg requested_by "$requested_by" \
            --arg job_id "$job_id" \
            '{
                version: 2,
                request_id: $request_id,
                action: $action,
                created_at: $created_at,
                requested_by: $requested_by,
                job_id: $job_id
            }' | write_request "$request_id"
    fi

    if [[ -n "$job_id" ]]; then
        echo "Submitted: $request_id"
        echo "Job:       $job_id"
        echo "Status:    $self status $job_id"
        echo "Logs:      $self logs $job_id"
    else
        echo "Submitted: $request_id"
        echo "Request:   $self status $request_id"
    fi
}

collect_common_options() {
    COMMON_CWD="$PWD"
    COMMON_LABEL=""
    COMMON_ID=""
    COMMON_GRACE_HOURS="2"
    COMMON_TIMEOUT_SEC="3600"
    COMMON_TIMEZONE="$(system_timezone)"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cwd)
                [[ $# -ge 2 ]] || die "--cwd requires a path"
                COMMON_CWD="$2"
                shift 2
                ;;
            --label)
                [[ $# -ge 2 ]] || die "--label requires a value"
                COMMON_LABEL="$2"
                shift 2
                ;;
            --id)
                [[ $# -ge 2 ]] || die "--id requires a value"
                COMMON_ID="$2"
                shift 2
                ;;
            --grace-hours)
                [[ $# -ge 2 ]] || die "--grace-hours requires a value"
                COMMON_GRACE_HOURS="$2"
                shift 2
                ;;
            --timeout-sec)
                [[ $# -ge 2 ]] || die "--timeout-sec requires a value"
                COMMON_TIMEOUT_SEC="$2"
                shift 2
                ;;
            --timezone)
                [[ $# -ge 2 ]] || die "--timezone requires a value"
                COMMON_TIMEZONE="$2"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            *)
                break
                ;;
        esac
    done

    container_cwd_ok "$COMMON_CWD" || die "Scheduled cwd must be under /home/dev/projects: $COMMON_CWD"
    [[ "$COMMON_GRACE_HOURS" =~ ^[0-9]+$ ]] || die "--grace-hours must be a whole number"
    [[ "$COMMON_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || die "--timeout-sec must be a whole number"

    REMAINING_ARGS=("$@")
}

build_job_json() {
    local schedule_json="$1"
    shift
    collect_common_options "$@"
    [[ ${#REMAINING_ARGS[@]} -gt 0 ]] || die "Missing command after --"

    local command job_id label
    command="$(command_from_args "${REMAINING_ARGS[@]}")"
    job_id="$(resolve_job_id "$COMMON_ID" "$COMMON_LABEL")"
    label="$COMMON_LABEL"
    [[ -n "$label" ]] || label="$job_id"

    jq -cn \
        --arg id "$job_id" \
        --arg label "$label" \
        --arg timezone "$COMMON_TIMEZONE" \
        --argjson schedule "$schedule_json" \
        --argjson grace_window_sec "$((COMMON_GRACE_HOURS * 3600))" \
        --arg cwd "$COMMON_CWD" \
        --arg command "$command" \
        --arg container_service "${AOC_SCHEDULE_CONTAINER_SERVICE:-dev}" \
        --arg compose_file "${AOC_SCHEDULE_COMPOSE_FILE:-docker-compose.macmini.yml}" \
        --argjson timeout_sec "$COMMON_TIMEOUT_SEC" \
        '{
            version: 2,
            id: $id,
            label: $label,
            timezone: $timezone,
            schedule: $schedule,
            grace_window_sec: $grace_window_sec,
            cwd: $cwd,
            command: $command,
            container_service: $container_service,
            compose_file: $compose_file,
            timeout_sec: $timeout_sec,
            enabled: true
        }'
}

cmd_at() {
    require_jq
    require_inbox
    [[ $# -ge 1 ]] || die "Missing local time"

    local local_time="$1"
    shift
    [[ "$local_time" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]] || die "Expected local time in 'YYYY-MM-DD HH:MM' format"

    local schedule_json job_json job_id
    schedule_json="$(jq -cn --arg local_time "$local_time" '{type:"once", local_time:$local_time}')"
    job_json="$(build_job_json "$schedule_json" "$@")"
    job_id="$(jq -r '.id' <<< "$job_json")"
    create_request create "$job_json" "$job_id"
}

cmd_hourly() {
    require_jq
    require_inbox

    local minute=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --minute)
                [[ $# -ge 2 ]] || die "--minute requires a value"
                minute="$2"
                shift 2
                ;;
            *)
                break
                ;;
        esac
    done
    [[ "$minute" =~ ^[0-9]+$ ]] || die "--minute is required"
    ((minute >= 0 && minute <= 59)) || die "--minute must be between 0 and 59"

    local schedule_json job_json job_id
    schedule_json="$(jq -cn --argjson minute "$minute" '{type:"hourly", minute:$minute}')"
    job_json="$(build_job_json "$schedule_json" "$@")"
    job_id="$(jq -r '.id' <<< "$job_json")"
    create_request create "$job_json" "$job_id"
}

cmd_daily() {
    require_jq
    require_inbox

    local time_value=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --time)
                [[ $# -ge 2 ]] || die "--time requires a value"
                time_value="$2"
                shift 2
                ;;
            *)
                break
                ;;
        esac
    done
    [[ -n "$time_value" ]] || die "--time is required"

    local hour minute schedule_json job_json job_id
    read -r hour minute <<< "$(parse_hhmm "$time_value")"
    schedule_json="$(jq -cn --argjson hour "$hour" --argjson minute "$minute" '{type:"daily", hour:$hour, minute:$minute}')"
    job_json="$(build_job_json "$schedule_json" "$@")"
    job_id="$(jq -r '.id' <<< "$job_json")"
    create_request create "$job_json" "$job_id"
}

cmd_weekly() {
    require_jq
    require_inbox

    local weekday="" time_value=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --weekday)
                [[ $# -ge 2 ]] || die "--weekday requires a value"
                weekday="$2"
                shift 2
                ;;
            --time)
                [[ $# -ge 2 ]] || die "--time requires a value"
                time_value="$2"
                shift 2
                ;;
            *)
                break
                ;;
        esac
    done
    [[ -n "$weekday" ]] || die "--weekday is required"
    [[ -n "$time_value" ]] || die "--time is required"

    local normalized hour minute schedule_json job_json job_id
    normalized="$(normalize_weekday "$weekday")"
    read -r hour minute <<< "$(parse_hhmm "$time_value")"
    schedule_json="$(jq -cn --arg weekday "$normalized" --argjson hour "$hour" --argjson minute "$minute" '{type:"weekly", weekday:$weekday, hour:$hour, minute:$minute}')"
    job_json="$(build_job_json "$schedule_json" "$@")"
    job_id="$(jq -r '.id' <<< "$job_json")"
    create_request create "$job_json" "$job_id"
}

cmd_monthly() {
    require_jq
    require_inbox

    local day="" time_value=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --day)
                [[ $# -ge 2 ]] || die "--day requires a value"
                day="$2"
                shift 2
                ;;
            --time)
                [[ $# -ge 2 ]] || die "--time requires a value"
                time_value="$2"
                shift 2
                ;;
            *)
                break
                ;;
        esac
    done
    [[ "$day" =~ ^[0-9]+$ ]] || die "--day is required"
    ((day >= 1 && day <= 31)) || die "--day must be between 1 and 31"
    [[ -n "$time_value" ]] || die "--time is required"

    local hour minute schedule_json job_json job_id
    read -r hour minute <<< "$(parse_hhmm "$time_value")"
    schedule_json="$(jq -cn --argjson day "$day" --argjson hour "$hour" --argjson minute "$minute" '{type:"monthly", day:$day, hour:$hour, minute:$minute}')"
    job_json="$(build_job_json "$schedule_json" "$@")"
    job_id="$(jq -r '.id' <<< "$job_json")"
    create_request create "$job_json" "$job_id"
}

cmd_delete() {
    require_jq
    require_inbox
    [[ $# -eq 1 ]] || die "Usage: aoc-schedule delete <job-id>"
    valid_id "$1" || die "Invalid job id: $1"
    create_request delete "" "$1"
}

cmd_enable() {
    require_jq
    require_inbox
    [[ $# -eq 1 ]] || die "Usage: aoc-schedule enable <job-id>"
    valid_id "$1" || die "Invalid job id: $1"
    create_request enable "" "$1"
}

cmd_disable() {
    require_jq
    require_inbox
    [[ $# -eq 1 ]] || die "Usage: aoc-schedule disable <job-id>"
    valid_id "$1" || die "Invalid job id: $1"
    create_request disable "" "$1"
}

cmd_run_now() {
    require_jq
    require_inbox
    [[ $# -eq 1 ]] || die "Usage: aoc-schedule run-now <job-id>"
    valid_id "$1" || die "Invalid job id: $1"
    create_request run-now "" "$1"
}

list_v2_jobs() {
    local job_file job_id status_file updated_at status schedule label

    shopt -s nullglob
    for job_file in "$JOBS_DIR"/*.json; do
        job_id="$(basename "$job_file" .json)"
        status_file="$STATUS_DIR/$job_id.json"
        updated_at="-"
        status="$(jq -r '.enabled // true | if . then "scheduled" else "disabled" end' "$job_file")"
        if [[ -f "$status_file" ]]; then
            updated_at="$(jq -r '.updated_at // "-" ' "$status_file")"
            status="$(jq -r '.status // "'"$status"'"' "$status_file")"
        fi
        schedule="$(schedule_display "$job_file")"
        label="$(jq -r '.label // .id' "$job_file")"
        printf '%s  %s  %s  %s  %s\n' "$updated_at" "$status" "$job_id" "$schedule" "$label"
    done | sort -r
}

list_v1_status() {
    shopt -s nullglob
    local files=("$STATUS_DIR"/*.json)
    if [[ ${#files[@]} -eq 0 ]]; then
        echo "No scheduled jobs found."
        return 0
    fi

    jq -r '
        [.updated_at // .created_at // "-",
         .id // "-",
         .status // "-",
         .time // .schedule // "-",
         .label // "",
         .command // ""] | @tsv
    ' "${files[@]}" | sort -r | while IFS=$'\t' read -r updated id status time label command; do
        if [[ -n "$label" ]]; then
            printf '%s  %s  %s  %s  %s\n' "$updated" "$status" "$id" "$time" "$label"
        else
            printf '%s  %s  %s  %s  %s\n' "$updated" "$status" "$id" "$time" "$command"
        fi
    done
}

cmd_list() {
    require_jq
    [[ -d "$STATUS_DIR" || -d "$JOBS_DIR" ]] || die "Schedule directories not found at $ROOT"

    if compgen -G "$JOBS_DIR/*.json" >/dev/null; then
        list_v2_jobs
    else
        list_v1_status
    fi
}

cmd_health() {
    require_jq
    [[ -f "$HEALTH_FILE" ]] || die "No scheduler health found at $HEALTH_FILE"
    jq . "$HEALTH_FILE"
}

cmd_status() {
    require_jq
    [[ $# -eq 1 ]] || die "Usage: aoc-schedule status <job-id-or-request-id>"
    valid_id "$1" || die "Invalid id: $1"

    local id="$1"
    local status_file="$STATUS_DIR/$id.json"
    local request_status_file="$REQUEST_STATUS_DIR/$id.json"
    local inbox_file="$INBOX_V2_DIR/$id.json"

    if [[ -f "$status_file" ]]; then
        jq . "$status_file"
        return 0
    fi

    if [[ -f "$request_status_file" ]]; then
        jq . "$request_status_file"
        return 0
    fi

    if [[ -f "$inbox_file" ]]; then
        echo "Request is still queued in the v2 inbox."
        jq . "$inbox_file"
        return 0
    fi

    die "No status found for id: $id"
}

cmd_logs() {
    [[ $# -ge 1 && $# -le 2 ]] || die "Usage: aoc-schedule logs <job-id> [lines]"
    valid_id "$1" || die "Invalid job id: $1"

    local lines="${2:-80}"
    [[ "$lines" =~ ^[0-9]+$ ]] || die "Line count must be numeric"

    local file="$LOG_DIR/$1.log"
    [[ -f "$file" ]] || die "No log found for job: $1"

    tail -n "$lines" "$file"
}

main() {
    local cmd="${1:-}"
    case "$cmd" in
        at)
            shift
            cmd_at "$@"
            ;;
        hourly)
            shift
            cmd_hourly "$@"
            ;;
        daily)
            shift
            cmd_daily "$@"
            ;;
        weekly)
            shift
            cmd_weekly "$@"
            ;;
        monthly)
            shift
            cmd_monthly "$@"
            ;;
        delete)
            shift
            cmd_delete "$@"
            ;;
        enable)
            shift
            cmd_enable "$@"
            ;;
        disable)
            shift
            cmd_disable "$@"
            ;;
        run-now)
            shift
            cmd_run_now "$@"
            ;;
        cancel)
            shift
            cmd_delete "$@"
            ;;
        list|"")
            [[ -z "$cmd" ]] || shift
            cmd_list
            ;;
        health)
            shift
            cmd_health "$@"
            ;;
        status)
            shift
            cmd_status "$@"
            ;;
        logs)
            shift
            cmd_logs "$@"
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
}

main "$@"
