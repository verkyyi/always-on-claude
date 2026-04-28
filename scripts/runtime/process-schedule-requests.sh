#!/bin/bash
# process-schedule-requests.sh — Host-side processor for container schedule requests.

set -euo pipefail

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
warn()  { echo "  WARN: $*" >&2; }

TARGET_USER="${AOC_USER:-dev}"
if command -v getent >/dev/null 2>&1; then
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
else
    TARGET_HOME="$(eval "printf '%s' ~$TARGET_USER")"
fi
TARGET_GROUP="$(id -gn "$TARGET_USER")"
DEV_ENV="${DEV_ENV:-$TARGET_HOME/dev-env}"
SCHEDULE_DIR="${AOC_SCHEDULE_DIR:-$TARGET_HOME/.always-on-claude/schedule}"
DOCKER_BIN="${AOC_DOCKER:-docker}"
DOCKER_COMPOSE_FILE="${AOC_DOCKER_COMPOSE_FILE-}"
DOCKER_SERVICE="${AOC_DOCKER_SERVICE:-dev}"
DOCKER_EXEC_PREFIX="${AOC_DOCKER_EXEC_PREFIX-sudo --preserve-env=HOME}"
CONTAINER_PROJECTS_DIR="${AOC_CONTAINER_PROJECTS_DIR:-/home/dev/projects}"
HOST_PROJECTS_DIR="${AOC_HOST_PROJECTS_DIR:-$TARGET_HOME/projects}"
AT_BACKEND="${AOC_AT_BACKEND:-at}"
CRON_BACKEND="${AOC_CRON_BACKEND:-crontab}"

INBOX_DIR="$SCHEDULE_DIR/inbox"
PROCESSING_DIR="$SCHEDULE_DIR/processing"
JOBS_DIR="$SCHEDULE_DIR/jobs"
LOG_DIR="$SCHEDULE_DIR/logs"
STATUS_DIR="$SCHEDULE_DIR/status"
RUN_DIR="$SCHEDULE_DIR/run"
LOCK_FILE="$SCHEDULE_DIR/.processor.lock"
LOCK_DIR="$SCHEDULE_DIR/.processor.lockdir"
HEALTH_FILE="$SCHEDULE_DIR/bridge-health.json"
JOB_TIMEOUT_SEC="${AOC_JOB_TIMEOUT_SEC:-7200}"

now_utc() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

health_epoch() {
    date +%s
}

valid_id() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

container_cwd_ok() {
    [[ "$1" == "$CONTAINER_PROJECTS_DIR" || "$1" == "$CONTAINER_PROJECTS_DIR"/* ]]
}

host_path_for_cwd() {
    local cwd="$1"
    local relative

    relative="${cwd#"$CONTAINER_PROJECTS_DIR"}"
    printf '%s%s\n' "$HOST_PROJECTS_DIR" "$relative"
}

cron_field_ok() {
    [[ "$1" =~ ^[A-Za-z0-9,*/.-]+$ ]]
}

cron_spec_ok() {
    local spec="$1"
    local fields=()
    read -r -a fields <<< "$spec"

    [[ ${#fields[@]} -eq 5 ]] || return 1

    local field
    for field in "${fields[@]}"; do
        cron_field_ok "$field" || return 1
    done
}

has_newline() {
    [[ "$1" == *$'\n'* || "$1" == *$'\r'* ]]
}

job_lock_dir() {
    printf '%s/%s.lock\n' "$RUN_DIR" "$1"
}

job_pid_file() {
    printf '%s/pid\n' "$(job_lock_dir "$1")"
}

job_lock_active() {
    local id="$1"
    local lock_dir pid_file pid

    lock_dir="$(job_lock_dir "$id")"
    [[ -d "$lock_dir" ]] || return 1

    pid_file="$(job_pid_file "$id")"
    if [[ -f "$pid_file" ]]; then
        pid="$(cat "$pid_file" 2>/dev/null || true)"
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi

    rm -rf "$lock_dir"
    return 1
}

count_active_job_locks() {
    local lock_dir count=0 id

    shopt -s nullglob
    for lock_dir in "$RUN_DIR"/*.lock; do
        id="$(basename "$lock_dir" .lock)"
        job_lock_active "$id" && count=$((count + 1))
    done
    printf '%s\n' "$count"
}

write_health() {
    local state="$1"
    local reason="${2:-}"
    local tmp existing_started_at
    local active_jobs

    mkdir -p "$RUN_DIR"
    active_jobs="$(count_active_job_locks)"
    existing_started_at=""
    if [[ -f "$HEALTH_FILE" ]]; then
        existing_started_at="$(jq -r '.last_started_at // empty' "$HEALTH_FILE" 2>/dev/null || true)"
    fi

    tmp=$(mktemp "$SCHEDULE_DIR/.health.tmp.XXXXXX")
    jq -n \
        --arg state "$state" \
        --arg reason "$reason" \
        --arg now "$(now_utc)" \
        --arg last_started_at "${existing_started_at:-$(now_utc)}" \
        --argjson last_tick_epoch "$(health_epoch)" \
        --argjson active_jobs "$active_jobs" \
        --argjson pid "$$" \
        '{
            state: $state,
            last_started_at: $last_started_at,
            last_completed_at: $now,
            last_tick_epoch: $last_tick_epoch,
            active_jobs: $active_jobs,
            processor_pid: $pid
        }
        | if $reason == "" then . else . + {reason: $reason} end' > "$tmp"
    mv "$tmp" "$HEALTH_FILE"
}

mark_health_started() {
    local tmp active_jobs

    mkdir -p "$RUN_DIR"
    active_jobs="$(count_active_job_locks)"
    tmp=$(mktemp "$SCHEDULE_DIR/.health.tmp.XXXXXX")
    jq -n \
        --arg state "running" \
        --arg now "$(now_utc)" \
        --argjson last_tick_epoch "$(health_epoch)" \
        --argjson active_jobs "$active_jobs" \
        --argjson pid "$$" \
        '{
            state: $state,
            last_started_at: $now,
            last_tick_epoch: $last_tick_epoch,
            active_jobs: $active_jobs,
            processor_pid: $pid
        }' > "$tmp"
    mv "$tmp" "$HEALTH_FILE"
}

write_invalid_status() {
    local id="$1"
    local reason="$2"
    local tmp

    valid_id "$id" || id="invalid-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    tmp=$(mktemp "$STATUS_DIR/.${id}.tmp.XXXXXX")
    jq -n \
        --arg id "$id" \
        --arg status "rejected" \
        --arg reason "$reason" \
        --arg updated_at "$(now_utc)" \
        '{id: $id, status: $status, reason: $reason, updated_at: $updated_at}' > "$tmp"
    mv "$tmp" "$STATUS_DIR/$id.json"
}

write_status_from_request() {
    local request="$1"
    local status="$2"
    local reason="${3:-}"
    local tmp id

    id=$(jq -r '.id // empty' "$request" 2>/dev/null || true)
    valid_id "$id" || id="$(basename "$request" .json)"
    valid_id "$id" || id="invalid-$(date -u +%Y%m%dT%H%M%SZ)-$$"

    tmp=$(mktemp "$STATUS_DIR/.${id}.tmp.XXXXXX")
    jq \
        --arg status "$status" \
        --arg reason "$reason" \
        --arg updated_at "$(now_utc)" \
        '. + {status: $status, updated_at: $updated_at}
         | if $reason == "" then del(.reason) else . + {reason: $reason} end' \
        "$request" > "$tmp"
    mv "$tmp" "$STATUS_DIR/$id.json"
}

update_status_file() {
    local status_file="$1"
    local status="$2"
    local exit_code="${3:-}"
    local tmp

    tmp=$(mktemp "$STATUS_DIR/.status.tmp.XXXXXX")
    if [[ -n "$exit_code" ]]; then
        jq \
            --arg status "$status" \
            --arg updated_at "$(now_utc)" \
            --argjson exit_code "$exit_code" \
            '.status = $status | .updated_at = $updated_at | .exit_code = $exit_code' \
            "$status_file" > "$tmp"
    else
        jq \
            --arg status "$status" \
            --arg updated_at "$(now_utc)" \
            '.status = $status | .updated_at = $updated_at' \
            "$status_file" > "$tmp"
    fi
    mv "$tmp" "$status_file"
}

reject_request() {
    local request="$1"
    local reason="$2"

    if jq -e . "$request" >/dev/null 2>&1; then
        write_status_from_request "$request" "rejected" "$reason"
    else
        write_invalid_status "$(basename "$request" .json)" "$reason"
    fi
    warn "Rejected $(basename "$request"): $reason"
}

create_job_script() {
    local id="$1"
    local cwd="$2"
    local command="$3"
    local status_file="$4"
    local log_file="$5"
    local job_script="$6"
    local recurring="${7:-false}"

    {
        printf '#!/bin/bash\n'
        printf 'set -uo pipefail\n'
        printf 'export HOME=%q\n' "$TARGET_HOME"
        printf 'DEV_ENV=%q\n' "$DEV_ENV"
        printf 'DOCKER_BIN=%q\n' "$DOCKER_BIN"
        printf 'DOCKER_COMPOSE_FILE=%q\n' "$DOCKER_COMPOSE_FILE"
        printf 'DOCKER_SERVICE=%q\n' "$DOCKER_SERVICE"
        printf 'DOCKER_EXEC_PREFIX=%q\n' "$DOCKER_EXEC_PREFIX"
        printf 'JOB_ID=%q\n' "$id"
        printf 'CWD=%q\n' "$cwd"
        printf 'COMMAND=%q\n' "$command"
        printf 'STATUS_FILE=%q\n' "$status_file"
        printf 'LOG_FILE=%q\n' "$log_file"
        printf 'RECURRING=%q\n' "$recurring"
        printf 'JOB_TIMEOUT_SEC=%q\n' "$JOB_TIMEOUT_SEC"
        cat <<'JOB'

now_utc() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

update_status() {
    local status="$1"
    local exit_code="${2:-}"
    local tmp
    local now

    now="$(now_utc)"

    tmp=$(mktemp "$(dirname "$STATUS_FILE")/.${JOB_ID}.tmp.XXXXXX")
    if [[ "$RECURRING" == "true" && "$status" == "running" ]]; then
        jq \
            --arg status "$status" \
            --arg updated_at "$now" \
            --arg last_started_at "$now" \
            '.status = $status
             | .updated_at = $updated_at
             | .last_started_at = $last_started_at
             | del(.worker_pid, .worker_state, .worker_started_at)' \
            "$STATUS_FILE" > "$tmp"
    elif [[ "$RECURRING" == "true" && -n "$exit_code" ]]; then
        jq \
            --arg status "scheduled" \
            --arg last_run_status "$status" \
            --arg updated_at "$now" \
            --arg last_finished_at "$now" \
            --argjson last_exit_code "$exit_code" \
            '.status = $status
             | .updated_at = $updated_at
             | .last_run_status = $last_run_status
             | .last_finished_at = $last_finished_at
             | .last_exit_code = $last_exit_code
             | del(.worker_pid, .worker_state, .worker_started_at)' \
            "$STATUS_FILE" > "$tmp"
    elif [[ -n "$exit_code" ]]; then
        jq \
            --arg status "$status" \
            --arg updated_at "$now" \
            --argjson exit_code "$exit_code" \
            '.status = $status
             | .updated_at = $updated_at
             | .exit_code = $exit_code
             | del(.worker_pid, .worker_state, .worker_started_at)' \
            "$STATUS_FILE" > "$tmp"
    else
        jq \
            --arg status "$status" \
            --arg updated_at "$now" \
            '.status = $status
             | .updated_at = $updated_at
             | del(.worker_pid, .worker_state, .worker_started_at)' \
            "$STATUS_FILE" > "$tmp"
    fi
    mv "$tmp" "$STATUS_FILE"
}

{
    echo "=== $(now_utc) job $JOB_ID starting ==="
    echo "cwd: $CWD"
    echo "command: $COMMAND"

    update_status running

    cd "$DEV_ENV" || exit 127

    compose_args=(compose)
    if [[ -n "$DOCKER_COMPOSE_FILE" ]]; then
        compose_args+=(-f "$DOCKER_COMPOSE_FILE")
    fi

    exec_prefix=()
    if [[ -n "$DOCKER_EXEC_PREFIX" ]]; then
        read -r -a exec_prefix <<< "$DOCKER_EXEC_PREFIX"
    fi

    docker_cmd=()
    if [[ ${#exec_prefix[@]} -gt 0 ]]; then
        docker_cmd+=("${exec_prefix[@]}")
    fi
    docker_cmd+=("$DOCKER_BIN" "${compose_args[@]}" exec -T -w "$CWD" "$DOCKER_SERVICE" bash -lc "$COMMAND")

    set +e
    if [[ "$JOB_TIMEOUT_SEC" =~ ^[0-9]+$ ]] && [[ "$JOB_TIMEOUT_SEC" -gt 0 ]]; then
        python3 - "$JOB_TIMEOUT_SEC" "${docker_cmd[@]}" <<'PY'
import subprocess
import sys

timeout = int(sys.argv[1])
cmd = sys.argv[2:]
if not cmd:
    raise SystemExit(127)

try:
    completed = subprocess.run(cmd, check=False, timeout=timeout)
except subprocess.TimeoutExpired:
    raise SystemExit(124)

raise SystemExit(completed.returncode)
PY
    else
        "${docker_cmd[@]}"
    fi
    rc=$?
    set -e

    if [[ "$rc" -eq 0 ]]; then
        echo "=== $(now_utc) job $JOB_ID succeeded ==="
        update_status succeeded "$rc"
    elif [[ "$rc" -eq 124 ]]; then
        echo "=== $(now_utc) job $JOB_ID timed out after ${JOB_TIMEOUT_SEC}s ==="
        update_status failed "$rc"
    else
        echo "=== $(now_utc) job $JOB_ID failed: exit $rc ==="
        update_status failed "$rc"
    fi

    exit "$rc"
} >> "$LOG_FILE" 2>&1
JOB
    } > "$job_script"

    chmod 700 "$job_script"
}

rebuild_job_script_from_status() {
    local status_file="$1"
    local id cwd command action log_file job_script

    id=$(jq -r '.id // empty' "$status_file" 2>/dev/null || true)
    cwd=$(jq -r '.cwd // empty' "$status_file" 2>/dev/null || true)
    command=$(jq -r '.command // empty' "$status_file" 2>/dev/null || true)
    action=$(jq -r '.action // empty' "$status_file" 2>/dev/null || true)

    valid_id "$id" || return 1
    [[ -n "$cwd" && -n "$command" ]] || return 1

    log_file="$LOG_DIR/$id.log"
    job_script="$JOBS_DIR/$id.sh"
    create_job_script "$id" "$cwd" "$command" "$status_file" "$log_file" "$job_script" "$([[ "$action" == "cron" ]] && echo true || echo false)"
}

reconcile_stale_running_jobs() {
    local status_file id action status tmp

    shopt -s nullglob
    for status_file in "$STATUS_DIR"/*.json; do
        id=$(jq -r '.id // empty' "$status_file" 2>/dev/null || true)
        action=$(jq -r '.action // empty' "$status_file" 2>/dev/null || true)
        status=$(jq -r '.status // empty' "$status_file" 2>/dev/null || true)

        valid_id "$id" || continue
        [[ "$status" == "running" ]] || continue
        job_lock_active "$id" && continue

        tmp=$(mktemp "$STATUS_DIR/.${id}.tmp.XXXXXX")
        if [[ "$action" == "cron" ]]; then
            jq \
                --arg status "scheduled" \
                --arg updated_at "$(now_utc)" \
                --arg last_run_status "failed" \
                --arg last_finished_at "$(now_utc)" \
                --arg reason "worker disappeared before completion" \
                --argjson last_exit_code 125 \
                '.status = $status
                 | .updated_at = $updated_at
                 | .last_run_status = $last_run_status
                 | .last_finished_at = $last_finished_at
                 | .last_exit_code = $last_exit_code
                 | .reason = $reason
                 | del(.worker_pid, .worker_state, .worker_started_at)' \
                "$status_file" > "$tmp"
        else
            jq \
                --arg status "failed" \
                --arg updated_at "$(now_utc)" \
                --arg reason "worker disappeared before completion" \
                --argjson exit_code 125 \
                '.status = $status
                 | .updated_at = $updated_at
                 | .exit_code = $exit_code
                 | .reason = $reason
                 | del(.worker_pid, .worker_state, .worker_started_at)' \
                "$status_file" > "$tmp"
        fi
        mv "$tmp" "$status_file"
        warn "Reconciled stale running job $id"
    done
}

mark_job_dispatched() {
    local status_file="$1"
    local worker_pid="$2"
    local tmp

    tmp=$(mktemp "$STATUS_DIR/.dispatch.tmp.XXXXXX")
    jq \
        --arg updated_at "$(now_utc)" \
        --arg worker_state "queued" \
        --arg worker_started_at "$(now_utc)" \
        --argjson worker_pid "$worker_pid" \
        '.updated_at = $updated_at
         | .worker_state = $worker_state
         | .worker_started_at = $worker_started_at
         | .worker_pid = $worker_pid' \
        "$status_file" > "$tmp"
    mv "$tmp" "$status_file"
}

launch_job_async() {
    local id="$1"
    local status_file="$2"
    local job_script="$3"
    local lock_dir pid_file bg_pid

    lock_dir="$(job_lock_dir "$id")"
    pid_file="$(job_pid_file "$id")"
    if job_lock_active "$id"; then
        warn "Job $id is already running"
        return 1
    fi

    mkdir -p "$RUN_DIR"
    mkdir "$lock_dir"

    nohup bash -c '
        set -euo pipefail
        lock_dir="$1"
        pid_file="$2"
        job_script="$3"
        printf "%s\n" "$$" > "$pid_file"
        bash "$job_script" || true
        rm -f "$pid_file"
        rmdir "$lock_dir" 2>/dev/null || true
    ' _ "$lock_dir" "$pid_file" "$job_script" >/dev/null 2>&1 &
    bg_pid=$!
    printf '%s\n' "$bg_pid" > "$pid_file"
    mark_job_dispatched "$status_file" "$bg_pid"
    return 0
}

parse_launchd_time_spec() {
    local time_spec="$1"

    python3 - "$time_spec" <<'PY'
import datetime as dt
import re
import sys

spec = sys.argv[1].strip().lower()
now = dt.datetime.now().astimezone()

def emit(value):
    if value <= now:
        value = value + dt.timedelta(days=1)
    print(f"{int(value.timestamp())}\t{value.isoformat(timespec='seconds')}")

match = re.fullmatch(r"now(?:\s*\+\s*(\d+)\s*(minute|minutes|min|mins|hour|hours|day|days))?", spec)
if match:
    count = int(match.group(1) or "0")
    unit = match.group(2) or "minutes"
    if unit.startswith("min"):
        due = now + dt.timedelta(minutes=count)
    elif unit.startswith("hour"):
        due = now + dt.timedelta(hours=count)
    else:
        due = now + dt.timedelta(days=count)
    print(f"{int(due.timestamp())}\t{due.isoformat(timespec='seconds')}")
    raise SystemExit(0)

match = re.fullmatch(r"(?:tomorrow\s+)?(\d{1,2}):(\d{2})(?:\s*(today|tomorrow))?", spec)
if match:
    hour = int(match.group(1))
    minute = int(match.group(2))
    day_word = match.group(3)
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        raise SystemExit("invalid clock time")
    due = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if spec.startswith("tomorrow") or day_word == "tomorrow":
        due += dt.timedelta(days=1)
    emit(due)
    raise SystemExit(0)

for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M"):
    try:
        parsed = dt.datetime.strptime(spec, fmt).replace(tzinfo=now.tzinfo)
    except ValueError:
        continue
    print(f"{int(parsed.timestamp())}\t{parsed.isoformat(timespec='seconds')}")
    raise SystemExit(0)

raise SystemExit("unsupported macOS launchd time spec")
PY
}

schedule_launchd_at_job() {
    local request="$1"
    local id="$2"
    local time_spec="$3"
    local label="$4"
    local status_file="$5"
    local log_file="$6"
    local due_info due_epoch due_at tmp

    if ! due_info=$(parse_launchd_time_spec "$time_spec" 2>&1); then
        update_status_file "$status_file" "rejected"
        tmp=$(mktemp "$STATUS_DIR/.${id}.tmp.XXXXXX")
        jq --arg reason "$due_info" '.reason = $reason' "$status_file" > "$tmp"
        mv "$tmp" "$status_file"
        warn "launchd rejected $id: $due_info"
        return 0
    fi

    IFS=$'\t' read -r due_epoch due_at <<< "$due_info"
    tmp=$(mktemp "$STATUS_DIR/.${id}.tmp.XXXXXX")
    jq \
        --arg status "scheduled" \
        --arg updated_at "$(now_utc)" \
        --arg host_at_job_id "launchd:$id" \
        --argjson host_due_epoch "$due_epoch" \
        --arg host_due_at "$due_at" \
        --arg log_file "$log_file" \
        --arg job_label "$label" \
        '.status = $status
         | .updated_at = $updated_at
         | .host_at_job_id = $host_at_job_id
         | .host_due_epoch = $host_due_epoch
         | .host_due_at = $host_due_at
         | .log_file = $log_file
         | .label = $job_label' \
        "$status_file" > "$tmp"
    mv "$tmp" "$status_file"

    ok "Scheduled $id for $due_at via launchd bridge"
    rm -f "$request"
}

cron_due_now() {
    local schedule="$1"
    local last_started_at="${2:-}"

    python3 - "$schedule" "$last_started_at" <<'PY'
import datetime as dt
import sys

schedule = sys.argv[1]
last_started_at = sys.argv[2]
now = dt.datetime.now().astimezone()
utc_minute = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M")

if last_started_at.startswith(utc_minute):
    raise SystemExit(1)

fields = schedule.split()
if len(fields) != 5:
    raise SystemExit(1)

def expand(field, low, high, normalize=None):
    values = set()
    for part in field.split(","):
        if not part:
            raise ValueError("empty cron field")
        if "/" in part:
            base, step_s = part.split("/", 1)
            step = int(step_s)
            if step < 1:
                raise ValueError("invalid step")
        else:
            base = part
            step = 1

        if base == "*":
            start, end = low, high
        elif "-" in base:
            start_s, end_s = base.split("-", 1)
            start, end = int(start_s), int(end_s)
        else:
            start = end = int(base)

        for value in range(start, end + 1, step):
            if normalize:
                value = normalize(value)
            if low <= value <= high:
                values.add(value)
    return values

def dow(value):
    return 0 if value == 7 else value

try:
    minute = expand(fields[0], 0, 59)
    hour = expand(fields[1], 0, 23)
    dom = expand(fields[2], 1, 31)
    month = expand(fields[3], 1, 12)
    day = expand(fields[4], 0, 6, dow)
except Exception:
    raise SystemExit(1)

dom_restricted = fields[2] != "*"
dow_restricted = fields[4] != "*"
cron_dow = (now.weekday() + 1) % 7

basic = now.minute in minute and now.hour in hour and now.month in month
if not basic:
    raise SystemExit(1)

if dom_restricted and dow_restricted:
    due = now.day in dom or cron_dow in day
else:
    due = now.day in dom and cron_dow in day

raise SystemExit(0 if due else 1)
PY
}

process_at_request() {
    local request="$1"
    local id time_spec cwd command label

    id=$(jq -r '.id // empty' "$request")
    time_spec=$(jq -r '.time // empty' "$request")
    cwd=$(jq -r '.cwd // empty' "$request")
    command=$(jq -r '.command // empty' "$request")
    label=$(jq -r '.label // empty' "$request")

    valid_id "$id" || { reject_request "$request" "Invalid id"; return 0; }
    [[ -n "$time_spec" ]] || { reject_request "$request" "Missing time"; return 0; }
    [[ -n "$cwd" ]] || { reject_request "$request" "Missing cwd"; return 0; }
    [[ -n "$command" ]] || { reject_request "$request" "Missing command"; return 0; }
    has_newline "$time_spec" && { reject_request "$request" "Time spec must be one line"; return 0; }
    container_cwd_ok "$cwd" || { reject_request "$request" "cwd must be under /home/dev/projects"; return 0; }

    local host_cwd
    host_cwd="$(host_path_for_cwd "$cwd")"
    if [[ ! -d "$host_cwd" ]]; then
        reject_request "$request" "cwd does not exist on host: $host_cwd"
        return 0
    fi

    if [[ -f "$STATUS_DIR/$id.json" ]]; then
        reject_request "$request" "Duplicate job id"
        return 0
    fi

    local status_file="$STATUS_DIR/$id.json"
    local log_file="$LOG_DIR/$id.log"
    local job_script="$JOBS_DIR/$id.sh"
    local at_output at_job_id tmp

    tmp=$(mktemp "$STATUS_DIR/.${id}.tmp.XXXXXX")
    jq \
        --arg status "accepted" \
        --arg updated_at "$(now_utc)" \
        '. + {status: $status, updated_at: $updated_at}' \
        "$request" > "$tmp"
    mv "$tmp" "$status_file"

    create_job_script "$id" "$cwd" "$command" "$status_file" "$log_file" "$job_script" false

    if [[ "$AT_BACKEND" == "launchd" ]]; then
        schedule_launchd_at_job "$request" "$id" "$time_spec" "$label" "$status_file" "$log_file"
        return 0
    fi

    if ! at_output=$(printf '/bin/bash %q\n' "$job_script" | at -M "$time_spec" 2>&1); then
        update_status_file "$status_file" "rejected"
        tmp=$(mktemp "$STATUS_DIR/.${id}.tmp.XXXXXX")
        jq --arg reason "$at_output" '.reason = $reason' "$status_file" > "$tmp"
        mv "$tmp" "$status_file"
        warn "at rejected $id: $at_output"
        return 0
    fi

    at_job_id=$(printf '%s\n' "$at_output" | sed -n 's/^job \([0-9][0-9]*\).*/\1/p' | head -1)
    tmp=$(mktemp "$STATUS_DIR/.${id}.tmp.XXXXXX")
    jq \
        --arg status "scheduled" \
        --arg updated_at "$(now_utc)" \
        --arg host_at_job_id "$at_job_id" \
        --arg log_file "$log_file" \
        --arg job_label "$label" \
        '.status = $status
         | .updated_at = $updated_at
         | .host_at_job_id = $host_at_job_id
         | .log_file = $log_file
         | .label = $job_label' \
        "$status_file" > "$tmp"
    mv "$tmp" "$status_file"

    ok "Scheduled $id${at_job_id:+ as at job $at_job_id}"
}

remove_crontab_entry() {
    local id="$1"
    local existing new

    existing=$(mktemp)
    new=$(mktemp)

    crontab -l > "$existing" 2>/dev/null || true
    awk -v id="$id" '
        $0 == "# always-on-claude schedule bridge BEGIN " id {
            skip = 1
            next
        }
        $0 == "# always-on-claude schedule bridge END " id {
            skip = 0
            next
        }
        !skip { print }
    ' "$existing" > "$new"

    crontab "$new"
    rm -f "$existing" "$new"
}

install_crontab_entry() {
    local id="$1"
    local schedule="$2"
    local job_script="$3"
    local existing new

    remove_crontab_entry "$id"

    existing=$(mktemp)
    new=$(mktemp)

    crontab -l > "$existing" 2>/dev/null || true
    cp "$existing" "$new"
    {
        echo "# always-on-claude schedule bridge BEGIN $id"
        printf '%s /bin/bash %q\n' "$schedule" "$job_script"
        echo "# always-on-claude schedule bridge END $id"
    } >> "$new"

    crontab "$new"
    rm -f "$existing" "$new"
}

process_cron_request() {
    local request="$1"
    local id schedule cwd command label

    id=$(jq -r '.id // empty' "$request")
    schedule=$(jq -r '.schedule // empty' "$request")
    cwd=$(jq -r '.cwd // empty' "$request")
    command=$(jq -r '.command // empty' "$request")
    label=$(jq -r '.label // empty' "$request")

    valid_id "$id" || { reject_request "$request" "Invalid id"; return 0; }
    [[ -n "$schedule" ]] || { reject_request "$request" "Missing schedule"; return 0; }
    [[ -n "$cwd" ]] || { reject_request "$request" "Missing cwd"; return 0; }
    [[ -n "$command" ]] || { reject_request "$request" "Missing command"; return 0; }
    has_newline "$schedule" && { reject_request "$request" "Cron schedule must be one line"; return 0; }
    cron_spec_ok "$schedule" || { reject_request "$request" "Cron schedule must be exactly five valid fields"; return 0; }
    container_cwd_ok "$cwd" || { reject_request "$request" "cwd must be under /home/dev/projects"; return 0; }
    if [[ "$CRON_BACKEND" != "launchd" ]]; then
        command -v crontab >/dev/null 2>&1 || { reject_request "$request" "crontab is not installed on the host"; return 0; }
    fi

    local host_cwd
    host_cwd="$(host_path_for_cwd "$cwd")"
    if [[ ! -d "$host_cwd" ]]; then
        reject_request "$request" "cwd does not exist on host: $host_cwd"
        return 0
    fi

    if [[ -f "$STATUS_DIR/$id.json" ]]; then
        reject_request "$request" "Duplicate job id"
        return 0
    fi

    local status_file="$STATUS_DIR/$id.json"
    local log_file="$LOG_DIR/$id.log"
    local job_script="$JOBS_DIR/$id.sh"
    local tmp

    tmp=$(mktemp "$STATUS_DIR/.${id}.tmp.XXXXXX")
    jq \
        --arg status "accepted" \
        --arg updated_at "$(now_utc)" \
        '. + {status: $status, updated_at: $updated_at}' \
        "$request" > "$tmp"
    mv "$tmp" "$status_file"

    create_job_script "$id" "$cwd" "$command" "$status_file" "$log_file" "$job_script" true
    if [[ "$CRON_BACKEND" == "launchd" ]]; then
        :
    else
        install_crontab_entry "$id" "$schedule" "$job_script"
    fi

    tmp=$(mktemp "$STATUS_DIR/.${id}.tmp.XXXXXX")
    jq \
        --arg status "scheduled" \
        --arg updated_at "$(now_utc)" \
        --arg log_file "$log_file" \
        --arg job_label "$label" \
        --arg host_cron_backend "$CRON_BACKEND" \
        '.status = $status
         | .updated_at = $updated_at
         | .log_file = $log_file
         | .label = $job_label
         | .host_cron_backend = $host_cron_backend' \
        "$status_file" > "$tmp"
    mv "$tmp" "$status_file"

    ok "Scheduled recurring job $id"
}

process_cancel_request() {
    local request="$1"
    local id target_id status_file current_status action at_job_id host_cron_backend tmp

    id=$(jq -r '.id // empty' "$request")
    target_id=$(jq -r '.target_id // empty' "$request")

    valid_id "$id" || { reject_request "$request" "Invalid id"; return 0; }
    valid_id "$target_id" || { reject_request "$request" "Invalid target_id"; return 0; }

    status_file="$STATUS_DIR/$target_id.json"
    [[ -f "$status_file" ]] || { reject_request "$request" "Target job not found"; return 0; }

    current_status=$(jq -r '.status // empty' "$status_file")
    action=$(jq -r '.action // empty' "$status_file")
    if [[ "$action" == "cron" ]]; then
        if [[ "$current_status" != "scheduled" && "$current_status" != "accepted" && "$current_status" != "running" ]]; then
            reject_request "$request" "Target job is not cancelable: $current_status"
            return 0
        fi
    elif [[ "$current_status" != "scheduled" && "$current_status" != "accepted" ]]; then
        reject_request "$request" "Target job is not cancelable: $current_status"
        return 0
    fi

    if [[ "$action" == "cron" ]]; then
        host_cron_backend=$(jq -r '.host_cron_backend // empty' "$status_file")
        if [[ "$host_cron_backend" != "launchd" ]]; then
            remove_crontab_entry "$target_id"
        fi
    else
        at_job_id=$(jq -r '.host_at_job_id // empty' "$status_file")
        if [[ "$at_job_id" == launchd:* ]]; then
            :
        elif [[ -n "$at_job_id" ]]; then
            if ! atrm "$at_job_id" 2>/dev/null; then
                reject_request "$request" "atrm failed for host at job $at_job_id"
                return 0
            fi
        fi
    fi

    tmp=$(mktemp "$STATUS_DIR/.${target_id}.tmp.XXXXXX")
    jq \
        --arg status "canceled" \
        --arg updated_at "$(now_utc)" \
        --arg canceled_by_request "$id" \
        '.status = $status | .updated_at = $updated_at | .canceled_by_request = $canceled_by_request' \
        "$status_file" > "$tmp"
    mv "$tmp" "$status_file"

    write_status_from_request "$request" "succeeded"
    ok "Canceled $target_id"
}

run_due_launchd_at_jobs() {
    [[ "$AT_BACKEND" == "launchd" ]] || return 0

    local now status_file id action status due job_script
    now=$(date +%s)

    shopt -s nullglob
    for status_file in "$STATUS_DIR"/*.json; do
        action=$(jq -r '.action // empty' "$status_file" 2>/dev/null || true)
        status=$(jq -r '.status // empty' "$status_file" 2>/dev/null || true)
        due=$(jq -r '.host_due_epoch // empty' "$status_file" 2>/dev/null || true)
        id=$(jq -r '.id // empty' "$status_file" 2>/dev/null || true)

        [[ "$action" == "at" && "$status" == "scheduled" && "$due" =~ ^[0-9]+$ ]] || continue
        (( due <= now )) || continue
        valid_id "$id" || continue

        job_script="$JOBS_DIR/$id.sh"
        rebuild_job_script_from_status "$status_file" || true
        if [[ -x "$job_script" ]]; then
            launch_job_async "$id" "$status_file" "$job_script" || true
        else
            update_status_file "$status_file" "failed" 127
            warn "Missing job script for due job $id: $job_script"
        fi
    done
}

run_due_launchd_cron_jobs() {
    [[ "$CRON_BACKEND" == "launchd" ]] || return 0

    local status_file id action status schedule last_started_at job_script

    shopt -s nullglob
    for status_file in "$STATUS_DIR"/*.json; do
        action=$(jq -r '.action // empty' "$status_file" 2>/dev/null || true)
        status=$(jq -r '.status // empty' "$status_file" 2>/dev/null || true)
        schedule=$(jq -r '.schedule // empty' "$status_file" 2>/dev/null || true)
        last_started_at=$(jq -r '.last_started_at // empty' "$status_file" 2>/dev/null || true)
        id=$(jq -r '.id // empty' "$status_file" 2>/dev/null || true)

        [[ "$action" == "cron" && "$status" == "scheduled" ]] || continue
        valid_id "$id" || continue
        cron_spec_ok "$schedule" || continue
        cron_due_now "$schedule" "$last_started_at" || continue

        job_script="$JOBS_DIR/$id.sh"
        rebuild_job_script_from_status "$status_file" || true
        if [[ -x "$job_script" ]]; then
            launch_job_async "$id" "$status_file" "$job_script" || true
        else
            update_status_file "$status_file" "failed" 127
            warn "Missing job script for recurring job $id: $job_script"
        fi
    done
}

reinstall_cron_from_status() {
    mkdir -p "$INBOX_DIR" "$PROCESSING_DIR" "$JOBS_DIR" "$LOG_DIR" "$STATUS_DIR"

    local status_file id action status schedule cwd command label host_cwd log_file job_script tmp

    shopt -s nullglob
    for status_file in "$STATUS_DIR"/*.json; do
        action=$(jq -r '.action // empty' "$status_file" 2>/dev/null || true)
        status=$(jq -r '.status // empty' "$status_file" 2>/dev/null || true)
        [[ "$action" == "cron" && "$status" == "scheduled" ]] || continue

        id=$(jq -r '.id // empty' "$status_file")
        schedule=$(jq -r '.schedule // empty' "$status_file")
        cwd=$(jq -r '.cwd // empty' "$status_file")
        command=$(jq -r '.command // empty' "$status_file")
        label=$(jq -r '.label // empty' "$status_file")

        valid_id "$id" || { warn "Skipping cron status with invalid id: $status_file"; continue; }
        cron_spec_ok "$schedule" || { warn "Skipping $id with invalid cron schedule"; continue; }
        container_cwd_ok "$cwd" || { warn "Skipping $id with invalid cwd: $cwd"; continue; }

        host_cwd="$(host_path_for_cwd "$cwd")"
        if [[ ! -d "$host_cwd" ]]; then
            warn "Skipping $id because host cwd is missing: $host_cwd"
            continue
        fi

        log_file="$LOG_DIR/$id.log"
        job_script="$JOBS_DIR/$id.sh"
        create_job_script "$id" "$cwd" "$command" "$status_file" "$log_file" "$job_script" true
        if [[ "$CRON_BACKEND" != "launchd" ]]; then
            install_crontab_entry "$id" "$schedule" "$job_script"
        fi

        tmp=$(mktemp "$STATUS_DIR/.${id}.tmp.XXXXXX")
        jq \
            --arg updated_at "$(now_utc)" \
            --arg log_file "$log_file" \
            --arg job_label "$label" \
            --arg host_cron_backend "$CRON_BACKEND" \
            '.updated_at = $updated_at
             | .log_file = $log_file
             | .label = $job_label
             | .host_cron_backend = $host_cron_backend' \
            "$status_file" > "$tmp"
        mv "$tmp" "$status_file"

        ok "Reinstalled recurring job $id"
    done
}

acquire_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            warn "Another schedule processor is already running"
            return 1
        fi
        return 0
    fi

    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        warn "Another schedule processor is already running"
        return 1
    fi
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
}

process_request() {
    local request="$1"
    local version action

    if ! jq -e . "$request" >/dev/null 2>&1; then
        reject_request "$request" "Invalid JSON"
        return 0
    fi

    version=$(jq -r '.version // empty' "$request")
    action=$(jq -r '.action // empty' "$request")

    [[ "$version" == "1" ]] || { reject_request "$request" "Unsupported request version"; return 0; }

    case "$action" in
        at)
            process_at_request "$request"
            ;;
        cron)
            process_cron_request "$request"
            ;;
        cancel)
            process_cancel_request "$request"
            ;;
        *)
            reject_request "$request" "Unsupported action: $action"
            ;;
    esac
}

main() {
    case "${1:-}" in
        --run-due-at)
            run_due_launchd_at_jobs
            return 0
            ;;
        --reinstall-cron)
            reinstall_cron_from_status
            return 0
            ;;
    esac

    mkdir -p "$INBOX_DIR" "$PROCESSING_DIR" "$JOBS_DIR" "$LOG_DIR" "$STATUS_DIR" "$RUN_DIR"
    if [[ $EUID -eq 0 ]]; then
        chown -R "$TARGET_USER:$TARGET_GROUP" "$SCHEDULE_DIR"
    fi

    mark_health_started
    if ! acquire_lock; then
        write_health "busy" "processor lock is held by another run"
        return 0
    fi

    shopt -s nullglob
    local request work
    for request in "$INBOX_DIR"/*.json; do
        work="$PROCESSING_DIR/$(basename "$request")"
        mv "$request" "$work" || continue
        process_request "$work" || true
        rm -f "$work"
    done

    reconcile_stale_running_jobs
    run_due_launchd_at_jobs
    run_due_launchd_cron_jobs
    write_health "idle"
}

main "$@"
