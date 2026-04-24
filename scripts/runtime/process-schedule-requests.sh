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

INBOX_DIR="$SCHEDULE_DIR/inbox"
PROCESSING_DIR="$SCHEDULE_DIR/processing"
JOBS_DIR="$SCHEDULE_DIR/jobs"
LOG_DIR="$SCHEDULE_DIR/logs"
STATUS_DIR="$SCHEDULE_DIR/status"
LOCK_FILE="$SCHEDULE_DIR/.processor.lock"

now_utc() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

valid_id() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

container_cwd_ok() {
    [[ "$1" == "/home/dev/projects" || "$1" == /home/dev/projects/* ]]
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
        printf 'JOB_ID=%q\n' "$id"
        printf 'CWD=%q\n' "$cwd"
        printf 'COMMAND=%q\n' "$command"
        printf 'STATUS_FILE=%q\n' "$status_file"
        printf 'LOG_FILE=%q\n' "$log_file"
        printf 'RECURRING=%q\n' "$recurring"
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
            '.status = $status | .updated_at = $updated_at | .last_started_at = $last_started_at' \
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
             | .last_exit_code = $last_exit_code' \
            "$STATUS_FILE" > "$tmp"
    elif [[ -n "$exit_code" ]]; then
        jq \
            --arg status "$status" \
            --arg updated_at "$now" \
            --argjson exit_code "$exit_code" \
            '.status = $status | .updated_at = $updated_at | .exit_code = $exit_code' \
            "$STATUS_FILE" > "$tmp"
    else
        jq \
            --arg status "$status" \
            --arg updated_at "$now" \
            '.status = $status | .updated_at = $updated_at' \
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

    set +e
    sudo --preserve-env=HOME docker compose exec -T -w "$CWD" dev bash -lc "$COMMAND"
    rc=$?
    set -e

    if [[ "$rc" -eq 0 ]]; then
        echo "=== $(now_utc) job $JOB_ID succeeded ==="
        update_status succeeded "$rc"
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

    if [[ ! -d "$cwd" ]]; then
        reject_request "$request" "cwd does not exist on host: $cwd"
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
    command -v crontab >/dev/null 2>&1 || { reject_request "$request" "crontab is not installed on the host"; return 0; }

    if [[ ! -d "$cwd" ]]; then
        reject_request "$request" "cwd does not exist on host: $cwd"
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
    install_crontab_entry "$id" "$schedule" "$job_script"

    tmp=$(mktemp "$STATUS_DIR/.${id}.tmp.XXXXXX")
    jq \
        --arg status "scheduled" \
        --arg updated_at "$(now_utc)" \
        --arg log_file "$log_file" \
        --arg job_label "$label" \
        '.status = $status
         | .updated_at = $updated_at
         | .log_file = $log_file
         | .label = $job_label' \
        "$status_file" > "$tmp"
    mv "$tmp" "$status_file"

    ok "Scheduled recurring job $id"
}

process_cancel_request() {
    local request="$1"
    local id target_id status_file current_status action at_job_id tmp

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
        remove_crontab_entry "$target_id"
    else
        at_job_id=$(jq -r '.host_at_job_id // empty' "$status_file")
        if [[ -n "$at_job_id" ]]; then
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
    mkdir -p "$INBOX_DIR" "$PROCESSING_DIR" "$JOBS_DIR" "$LOG_DIR" "$STATUS_DIR"
    if [[ $EUID -eq 0 ]]; then
        chown -R "$TARGET_USER:$TARGET_GROUP" "$SCHEDULE_DIR"
    fi

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        warn "Another schedule processor is already running"
        exit 0
    fi

    shopt -s nullglob
    local request work
    for request in "$INBOX_DIR"/*.json; do
        work="$PROCESSING_DIR/$(basename "$request")"
        mv "$request" "$work" || continue
        process_request "$work" || true
        rm -f "$work"
    done
}

main "$@"
