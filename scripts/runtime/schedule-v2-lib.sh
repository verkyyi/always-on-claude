#!/bin/bash
# schedule-v2-lib.sh — Shared helpers for v2 local-time native scheduling.

set -euo pipefail

schedule_v2_root() {
    if [[ -n "${AOC_SCHEDULE_DIR:-}" ]]; then
        printf '%s\n' "$AOC_SCHEDULE_DIR"
    else
        printf '%s\n' "$HOME/.always-on-claude/schedule"
    fi
}

SCHEDULE_V2_ROOT="${AOC_SCHEDULE_DIR:-$(schedule_v2_root)}"
SCHEDULE_V2_JOBS_DIR="$SCHEDULE_V2_ROOT/jobs"
SCHEDULE_V2_STATUS_DIR="$SCHEDULE_V2_ROOT/status"
SCHEDULE_V2_LOGS_DIR="$SCHEDULE_V2_ROOT/logs"
SCHEDULE_V2_RUNS_DIR="$SCHEDULE_V2_ROOT/runs"
SCHEDULE_V2_LOCKS_DIR="$SCHEDULE_V2_ROOT/locks"
SCHEDULE_V2_INBOX_DIR="$SCHEDULE_V2_ROOT/inbox-v2"
SCHEDULE_V2_REQUEST_STATUS_DIR="$SCHEDULE_V2_ROOT/request-status"
SCHEDULE_V2_HEALTH_FILE="$SCHEDULE_V2_ROOT/bridge-health.json"

schedule_v2_die() {
    echo "ERROR: $*" >&2
    exit 1
}

schedule_v2_now_local() {
    date +%Y-%m-%dT%H:%M:%S%z
}

schedule_v2_now_utc() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

schedule_v2_detect_timezone() {
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

schedule_v2_job_def_path() {
    printf '%s/%s.json\n' "$SCHEDULE_V2_JOBS_DIR" "$1"
}

schedule_v2_job_status_path() {
    printf '%s/%s.json\n' "$SCHEDULE_V2_STATUS_DIR" "$1"
}

schedule_v2_job_log_path() {
    printf '%s/%s.log\n' "$SCHEDULE_V2_LOGS_DIR" "$1"
}

schedule_v2_slot_dir() {
    printf '%s/%s\n' "$SCHEDULE_V2_RUNS_DIR" "$1"
}

schedule_v2_slot_path() {
    printf '%s/%s.json\n' "$(schedule_v2_slot_dir "$1")" "$2"
}

schedule_v2_lock_dir() {
    printf '%s/%s.lock\n' "$SCHEDULE_V2_LOCKS_DIR" "$1"
}

schedule_v2_request_path() {
    printf '%s/%s.json\n' "$SCHEDULE_V2_INBOX_DIR" "$1"
}

schedule_v2_request_status_path() {
    printf '%s/%s.json\n' "$SCHEDULE_V2_REQUEST_STATUS_DIR" "$1"
}

schedule_v2_ensure_dirs() {
    mkdir -p \
        "$SCHEDULE_V2_JOBS_DIR" \
        "$SCHEDULE_V2_STATUS_DIR" \
        "$SCHEDULE_V2_LOGS_DIR" \
        "$SCHEDULE_V2_RUNS_DIR" \
        "$SCHEDULE_V2_LOCKS_DIR" \
        "$SCHEDULE_V2_INBOX_DIR" \
        "$SCHEDULE_V2_REQUEST_STATUS_DIR"
}

schedule_v2_list_job_ids() {
    local file
    shopt -s nullglob
    for file in "$SCHEDULE_V2_JOBS_DIR"/*.json; do
        basename "$file" .json
    done
}

schedule_v2_count_enabled_jobs() {
    local count=0 job_id
    for job_id in $(schedule_v2_list_job_ids); do
        if jq -e '.enabled // true' "$(schedule_v2_job_def_path "$job_id")" >/dev/null 2>&1; then
            count=$((count + 1))
        fi
    done
    printf '%s\n' "$count"
}

schedule_v2_count_active_jobs() {
    local count=0 lock_dir pid
    shopt -s nullglob
    for lock_dir in "$SCHEDULE_V2_LOCKS_DIR"/*.lock; do
        pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            count=$((count + 1))
        fi
    done
    printf '%s\n' "$count"
}

schedule_v2_write_health() {
    local state="$1"
    local tmp

    schedule_v2_ensure_dirs
    tmp="$(mktemp "$SCHEDULE_V2_ROOT/.health.tmp.XXXXXX")"
    jq -n \
        --arg state "$state" \
        --arg timezone "$(schedule_v2_detect_timezone)" \
        --arg last_recovery_check_at "$(schedule_v2_now_local)" \
        --argjson active_jobs "$(schedule_v2_count_active_jobs)" \
        --argjson enabled_jobs "$(schedule_v2_count_enabled_jobs)" \
        '{
            state: $state,
            timezone: $timezone,
            last_recovery_check_at: $last_recovery_check_at,
            active_jobs: $active_jobs,
            enabled_jobs: $enabled_jobs
        }' > "$tmp"
    mv "$tmp" "$SCHEDULE_V2_HEALTH_FILE"
}

schedule_v2_load_job() {
    local job_id="$1"
    local job_file

    job_file="$(schedule_v2_job_def_path "$job_id")"
    [[ -f "$job_file" ]] || schedule_v2_die "Job definition not found: $job_file"

    export SCHEDULE_V2_JOB_FILE="$job_file"
    export SCHEDULE_V2_JOB_ID="$job_id"
    export SCHEDULE_V2_JOB_LABEL
    SCHEDULE_V2_JOB_LABEL="$(jq -r '.label // .id' "$job_file")"
    export SCHEDULE_V2_JOB_TIMEZONE
    SCHEDULE_V2_JOB_TIMEZONE="$(jq -r '.timezone // empty' "$job_file")"
    [[ -n "$SCHEDULE_V2_JOB_TIMEZONE" ]] || schedule_v2_die "Job timezone is required: $job_file"
    export SCHEDULE_V2_JOB_GRACE_WINDOW_SEC
    SCHEDULE_V2_JOB_GRACE_WINDOW_SEC="$(jq -r '.grace_window_sec // 0' "$job_file")"
    export SCHEDULE_V2_JOB_CWD
    SCHEDULE_V2_JOB_CWD="$(jq -r '.cwd // empty' "$job_file")"
    export SCHEDULE_V2_JOB_COMMAND
    SCHEDULE_V2_JOB_COMMAND="$(jq -r '.command // empty' "$job_file")"
    export SCHEDULE_V2_JOB_CONTAINER_SERVICE
    SCHEDULE_V2_JOB_CONTAINER_SERVICE="$(jq -r '.container_service // "dev"' "$job_file")"
    export SCHEDULE_V2_JOB_COMPOSE_FILE
    SCHEDULE_V2_JOB_COMPOSE_FILE="$(jq -r '.compose_file // empty' "$job_file")"
    export SCHEDULE_V2_JOB_TIMEOUT_SEC
    SCHEDULE_V2_JOB_TIMEOUT_SEC="$(jq -r '.timeout_sec // 0' "$job_file")"
    export SCHEDULE_V2_JOB_ENABLED
    SCHEDULE_V2_JOB_ENABLED="$(jq -r '.enabled // true' "$job_file")"
    export SCHEDULE_V2_JOB_SCHEDULE_JSON
    SCHEDULE_V2_JOB_SCHEDULE_JSON="$(jq -c '.schedule' "$job_file")"

    [[ -n "$SCHEDULE_V2_JOB_CWD" ]] || schedule_v2_die "Job cwd is required: $job_file"
    [[ -n "$SCHEDULE_V2_JOB_COMMAND" ]] || schedule_v2_die "Job command is required: $job_file"
}

schedule_v2_compute_slot() {
    local job_file="$1"
    local reference_time="${2:-}"

    python3 - "$job_file" "$reference_time" <<'PY'
import json
import sys
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

job_file = sys.argv[1]
reference_time = sys.argv[2]

with open(job_file, "r", encoding="utf-8") as fh:
    job = json.load(fh)

tz = ZoneInfo(job["timezone"])
schedule = job["schedule"]
kind = schedule["type"]

if reference_time:
    try:
        now = datetime.fromisoformat(reference_time)
    except ValueError:
        now = datetime.strptime(reference_time, "%Y-%m-%dT%H:%M:%S%z")
    if now.tzinfo is None:
        now = now.replace(tzinfo=tz)
    else:
        now = now.astimezone(tz)
else:
    now = datetime.now(tz)

def fmt(dt):
    return dt.strftime("%Y-%m-%dT%H:%M")

if kind == "hourly":
    minute = int(schedule["minute"])
    slot = now.replace(minute=minute, second=0, microsecond=0)
    if slot > now:
        slot -= timedelta(hours=1)
    print(fmt(slot))
elif kind == "daily":
    hour = int(schedule["hour"])
    minute = int(schedule["minute"])
    slot = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if slot > now:
        slot -= timedelta(days=1)
    print(fmt(slot))
elif kind == "daily_hours":
    minute = int(schedule["minute"])
    hours = sorted(int(h) for h in schedule["hours"])
    if not hours:
        raise SystemExit("daily_hours requires at least one hour")
    slot = None
    for hour in reversed(hours):
        candidate = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
        if candidate <= now:
            slot = candidate
            break
    if slot is None:
        slot = (now - timedelta(days=1)).replace(hour=hours[-1], minute=minute, second=0, microsecond=0)
    print(fmt(slot))
elif kind == "weekly":
    weekdays = {
        "monday": 0, "tuesday": 1, "wednesday": 2, "thursday": 3,
        "friday": 4, "saturday": 5, "sunday": 6,
    }
    target = weekdays[schedule["weekday"].lower()]
    hour = int(schedule["hour"])
    minute = int(schedule["minute"])
    slot = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    delta = (slot.weekday() - target) % 7
    slot -= timedelta(days=delta)
    if slot > now:
        slot -= timedelta(days=7)
    print(fmt(slot))
elif kind == "monthly":
    day = int(schedule["day"])
    hour = int(schedule["hour"])
    minute = int(schedule["minute"])

    def month_slot(dt):
        while True:
            try:
                return dt.replace(day=day, hour=hour, minute=minute, second=0, microsecond=0)
            except ValueError:
                day_dt = dt.replace(day=1, hour=hour, minute=minute, second=0, microsecond=0)
                dt = day_dt - timedelta(days=1)

    slot = month_slot(now)
    if slot > now:
        prev_month = now.replace(day=1, hour=hour, minute=minute, second=0, microsecond=0) - timedelta(days=1)
        slot = month_slot(prev_month)
    print(fmt(slot))
elif kind == "once":
    dt = datetime.strptime(schedule["local_time"], "%Y-%m-%d %H:%M").replace(tzinfo=tz)
    print(fmt(dt))
else:
    raise SystemExit(f"unsupported schedule type: {kind}")
PY
}

schedule_v2_slot_epoch() {
    local job_file="$1"
    local slot="$2"

    python3 - "$job_file" "$slot" <<'PY'
import json
import sys
from datetime import datetime
from zoneinfo import ZoneInfo

job_file = sys.argv[1]
slot = sys.argv[2]

with open(job_file, "r", encoding="utf-8") as fh:
    job = json.load(fh)

tz = ZoneInfo(job["timezone"])
dt = datetime.strptime(slot, "%Y-%m-%dT%H:%M").replace(tzinfo=tz)
print(int(dt.timestamp()))
PY
}

schedule_v2_now_epoch() {
    date +%s
}

schedule_v2_slot_age_sec() {
    local job_file="$1"
    local slot="$2"
    local now_epoch slot_epoch

    now_epoch="$(schedule_v2_now_epoch)"
    slot_epoch="$(schedule_v2_slot_epoch "$job_file" "$slot")"
    printf '%s\n' "$((now_epoch - slot_epoch))"
}

schedule_v2_slot_within_grace() {
    local job_file="$1"
    local slot="$2"
    local age grace

    grace="$(jq -r '.grace_window_sec // 0' "$job_file")"
    age="$(schedule_v2_slot_age_sec "$job_file" "$slot")"
    [[ "$age" -ge 0 && "$age" -le "$grace" ]]
}

schedule_v2_slot_status() {
    local slot_file

    slot_file="$(schedule_v2_slot_path "$1" "$2")"
    if [[ -f "$slot_file" ]]; then
        jq -r '.status // empty' "$slot_file"
    fi
}

schedule_v2_slot_terminal() {
    local status

    status="$(schedule_v2_slot_status "$1" "$2")"
    [[ "$status" == "succeeded" || "$status" == "failed" || "$status" == "canceled" || "$status" == "missed" ]]
}

schedule_v2_slot_running() {
    local status

    status="$(schedule_v2_slot_status "$1" "$2")"
    [[ "$status" == "running" ]]
}

schedule_v2_write_slot_ledger() {
    local job_id="$1"
    local slot="$2"
    local run_mode="$3"
    local status="$4"
    local exit_code="${5:-}"
    local reason="${6:-}"
    local started_at="${7:-}"
    local finished_at="${8:-}"
    local slot_dir slot_file tmp

    slot_dir="$(schedule_v2_slot_dir "$job_id")"
    slot_file="$(schedule_v2_slot_path "$job_id" "$slot")"
    mkdir -p "$slot_dir"
    tmp="$(mktemp "$slot_dir/.${slot}.tmp.XXXXXX")"

    jq -n \
        --arg job_id "$job_id" \
        --arg slot "$slot" \
        --arg timezone "$SCHEDULE_V2_JOB_TIMEZONE" \
        --arg run_mode "$run_mode" \
        --arg status "$status" \
        --arg started_at "$started_at" \
        --arg finished_at "$finished_at" \
        --arg reason "$reason" \
        --argjson exit_code "${exit_code:-null}" \
        '{
            job_id: $job_id,
            slot: $slot,
            timezone: $timezone,
            run_mode: $run_mode,
            status: $status
        }
        | if $started_at == "" then . else . + {started_at: $started_at} end
        | if $finished_at == "" then . else . + {finished_at: $finished_at} end
        | if $reason == "" then . else . + {reason: $reason} end
        | if $exit_code == null then . else . + {exit_code: $exit_code} end' > "$tmp"
    mv "$tmp" "$slot_file"
}

schedule_v2_mark_slot_missed() {
    local job_id="$1"
    local slot="$2"
    local run_mode="${3:-catchup}"
    local reason="${4:-outside grace window}"

    schedule_v2_write_slot_ledger "$job_id" "$slot" "$run_mode" "missed" "" "$reason" "" "$(schedule_v2_now_local)"
    schedule_v2_write_status "$job_id" "$slot" "scheduled" "$run_mode" "missed" "" "$reason"
}

schedule_v2_write_status() {
    local job_id="$1"
    local slot="$2"
    local status="$3"
    local run_mode="$4"
    local run_status="${5:-}"
    local exit_code="${6:-}"
    local reason="${7:-}"
    local now_local now_utc status_file tmp

    now_local="$(schedule_v2_now_local)"
    now_utc="$(schedule_v2_now_utc)"
    status_file="$(schedule_v2_job_status_path "$job_id")"
    mkdir -p "$SCHEDULE_V2_STATUS_DIR"
    tmp="$(mktemp "$SCHEDULE_V2_STATUS_DIR/.${job_id}.tmp.XXXXXX")"

    if [[ -f "$status_file" ]]; then
        jq \
            --arg id "$job_id" \
            --arg label "$SCHEDULE_V2_JOB_LABEL" \
            --arg timezone "$SCHEDULE_V2_JOB_TIMEZONE" \
            --arg status "$status" \
            --arg slot "$slot" \
            --arg run_mode "$run_mode" \
            --arg updated_at "$now_local" \
            --arg run_status "$run_status" \
            --arg reason "$reason" \
            --argjson exit_code "${exit_code:-null}" \
            '
            .id = $id
            | .label = $label
            | .timezone = $timezone
            | .status = $status
            | .updated_at = $updated_at
            | if $status == "running" then
                .current_slot = $slot
                | .last_started_slot = $slot
                | .last_started_at = $updated_at
                | .last_run_mode = $run_mode
              else
                .current_slot = null
                | .last_finished_slot = $slot
                | .last_finished_at = $updated_at
                | if $run_status == "" then . else .last_run_status = $run_status end
                | if $exit_code == null then . else .last_exit_code = $exit_code end
                | if $run_status == "succeeded" then .last_successful_slot = $slot else . end
                | if $reason == "" then del(.reason) else .reason = $reason end
              end
            | .log_file = "'"$(schedule_v2_job_log_path "$job_id")"'"
            ' "$status_file" > "$tmp"
    else
        jq -n \
            --arg id "$job_id" \
            --arg label "$SCHEDULE_V2_JOB_LABEL" \
            --arg timezone "$SCHEDULE_V2_JOB_TIMEZONE" \
            --arg status "$status" \
            --arg slot "$slot" \
            --arg run_mode "$run_mode" \
            --arg updated_at "$now_local" \
            --arg run_status "$run_status" \
            --arg reason "$reason" \
            --arg log_file "$(schedule_v2_job_log_path "$job_id")" \
            --argjson exit_code "${exit_code:-null}" \
            '{
                id: $id,
                label: $label,
                timezone: $timezone,
                status: $status,
                updated_at: $updated_at,
                log_file: $log_file
            }
            | if $status == "running" then
                . + {
                    current_slot: $slot,
                    last_started_slot: $slot,
                    last_started_at: $updated_at,
                    last_run_mode: $run_mode
                }
              else
                . + {
                    current_slot: null,
                    last_finished_slot: $slot,
                    last_finished_at: $updated_at,
                    last_run_mode: $run_mode
                }
                | if $run_status == "" then . else . + {last_run_status: $run_status} end
                | if $exit_code == null then . else . + {last_exit_code: $exit_code} end
                | if $run_status == "succeeded" then . + {last_successful_slot: $slot} else . end
                | if $reason == "" then . else . + {reason: $reason} end
              end' > "$tmp"
    fi

    mv "$tmp" "$status_file"
    : "$now_utc"
}

schedule_v2_acquire_lock() {
    local job_id="$1"
    local lock_dir

    lock_dir="$(schedule_v2_lock_dir "$job_id")"
    mkdir -p "$SCHEDULE_V2_LOCKS_DIR"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        return 1
    fi
    printf '%s\n' "$$" > "$lock_dir/pid"
    return 0
}

schedule_v2_release_lock() {
    local job_id="$1"
    local lock_dir

    lock_dir="$(schedule_v2_lock_dir "$job_id")"
    rm -f "$lock_dir/pid"
    rmdir "$lock_dir" 2>/dev/null || true
}

schedule_v2_run_container_command() {
    local docker_bin compose_file service cwd command timeout_sec wrapped_command
    local -a cmd

    docker_bin="${AOC_DOCKER:-docker}"
    compose_file="${SCHEDULE_V2_JOB_COMPOSE_FILE:-}"
    service="${SCHEDULE_V2_JOB_CONTAINER_SERVICE}"
    cwd="${SCHEDULE_V2_JOB_CWD}"
    command="${SCHEDULE_V2_JOB_COMMAND}"
    timeout_sec="${SCHEDULE_V2_JOB_TIMEOUT_SEC:-0}"

    wrapped_command=$(printf 'export AOC_SCHEDULE_SLOT=%q AOC_SCHEDULE_SLOT_DATE=%q AOC_SCHEDULE_RUN_MODE=%q; %s' \
        "${SCHEDULE_V2_RUN_SLOT:-}" \
        "${SCHEDULE_V2_RUN_SLOT_DATE:-}" \
        "${SCHEDULE_V2_RUN_MODE:-}" \
        "$command")

    cmd=("$docker_bin" compose)
    if [[ -n "$compose_file" ]]; then
        cmd+=(-f "$compose_file")
    fi
    cmd+=(exec -T -w "$cwd" "$service" bash -lc "$wrapped_command")

    if [[ "$timeout_sec" =~ ^[0-9]+$ ]] && [[ "$timeout_sec" -gt 0 ]]; then
        python3 - "$timeout_sec" "${cmd[@]}" <<'PY'
import subprocess
import sys

timeout = int(sys.argv[1])
cmd = sys.argv[2:]
completed = subprocess.run(cmd, check=False, timeout=timeout)
raise SystemExit(completed.returncode)
PY
    else
        "${cmd[@]}"
    fi
}
