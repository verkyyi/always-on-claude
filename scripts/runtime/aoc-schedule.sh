#!/bin/bash
# aoc-schedule.sh — Submit scheduled container jobs to the host bridge.
#
# Intended to run inside the dev container. It writes request JSON into a
# bind-mounted inbox; a host-side systemd path unit validates and submits the
# job to the host atd service.

set -euo pipefail

die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  aoc-schedule at <time-spec> [--cwd <container-path>] [--label <name>] -- <command>
  aoc-schedule cron <5-field-spec> [--cwd <container-path>] [--label <name>] -- <command>
  aoc-schedule list
  aoc-schedule status <job-id>
  aoc-schedule logs <job-id> [lines]
  aoc-schedule cancel <job-id>

Examples:
  aoc-schedule at "now + 2 hours" -- "npm test"
  aoc-schedule cron "0 3 * * *" -- "npm test"
  aoc-schedule at "03:00 tomorrow" --cwd /home/dev/projects/app -- ./scripts/nightly.sh
  aoc-schedule list
  aoc-schedule logs 20260424T030000Z-a1b2c3d4
EOF
}

schedule_root() {
    if [[ -n "${AOC_SCHEDULE_DIR:-}" ]]; then
        echo "$AOC_SCHEDULE_DIR"
    elif [[ -d "$HOME/.aoc/schedule" || -d "$HOME/.aoc" ]]; then
        echo "$HOME/.aoc/schedule"
    else
        echo "$HOME/.always-on-claude/schedule"
    fi
}

ROOT="$(schedule_root)"
INBOX_DIR="$ROOT/inbox"
STATUS_DIR="$ROOT/status"
LOG_DIR="$ROOT/logs"

require_jq() {
    command -v jq >/dev/null 2>&1 || die "jq is required"
}

require_inbox() {
    [[ -d "$INBOX_DIR" ]] || die "Schedule bridge inbox not found at $INBOX_DIR. Run /update on the host and restart the container."
    [[ -w "$INBOX_DIR" ]] || die "Schedule bridge inbox is not writable: $INBOX_DIR"
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
    local tmp="$INBOX_DIR/.${id}.tmp"
    local dest="$INBOX_DIR/${id}.json"

    umask 077
    cat > "$tmp"
    mv "$tmp" "$dest"
}

cmd_at() {
    require_jq
    require_inbox

    [[ $# -ge 1 ]] || die "Missing time spec"

    local time_spec="$1"
    local cwd="$PWD"
    local label=""
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cwd)
                [[ $# -ge 2 ]] || die "--cwd requires a path"
                cwd="$2"
                shift 2
                ;;
            --label)
                [[ $# -ge 2 ]] || die "--label requires a value"
                label="$2"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            *)
                die "Unknown option before --: $1"
                ;;
        esac
    done

    [[ $# -gt 0 ]] || die "Missing command after --"
    container_cwd_ok "$cwd" || die "Scheduled cwd must be under /home/dev/projects: $cwd"

    local command id created_at
    command="$(command_from_args "$@")"
    id="$(new_id)"
    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    jq -n \
        --arg id "$id" \
        --arg action "at" \
        --arg time "$time_spec" \
        --arg cwd "$cwd" \
        --arg command "$command" \
        --arg job_label "$label" \
        --arg created_at "$created_at" \
        --arg requested_by "$(whoami 2>/dev/null || echo dev)" \
        '{
            version: 1,
            id: $id,
            action: $action,
            time: $time,
            cwd: $cwd,
            command: $command,
            "label": $job_label,
            created_at: $created_at,
            requested_by: $requested_by
        }' | write_request "$id"

    local self
    self="$(self_cmd)"

    echo "Submitted: $id"
    echo "Status:    $self status $id"
    echo "Logs:      $self logs $id"
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

cmd_cron() {
    require_jq
    require_inbox

    [[ $# -ge 1 ]] || die "Missing cron spec"

    local schedule="$1"
    local cwd="$PWD"
    local label=""
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cwd)
                [[ $# -ge 2 ]] || die "--cwd requires a path"
                cwd="$2"
                shift 2
                ;;
            --label)
                [[ $# -ge 2 ]] || die "--label requires a value"
                label="$2"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            *)
                die "Unknown option before --: $1"
                ;;
        esac
    done

    [[ $# -gt 0 ]] || die "Missing command after --"
    cron_spec_ok "$schedule" || die "Cron spec must be exactly five fields using cron syntax: $schedule"
    container_cwd_ok "$cwd" || die "Scheduled cwd must be under /home/dev/projects: $cwd"

    local command id created_at
    command="$(command_from_args "$@")"
    id="$(new_id)"
    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    jq -n \
        --arg id "$id" \
        --arg action "cron" \
        --arg schedule "$schedule" \
        --arg cwd "$cwd" \
        --arg command "$command" \
        --arg job_label "$label" \
        --arg created_at "$created_at" \
        --arg requested_by "$(whoami 2>/dev/null || echo dev)" \
        '{
            version: 1,
            id: $id,
            action: $action,
            schedule: $schedule,
            cwd: $cwd,
            command: $command,
            "label": $job_label,
            created_at: $created_at,
            requested_by: $requested_by
        }' | write_request "$id"

    local self
    self="$(self_cmd)"

    echo "Submitted: $id"
    echo "Status:    $self status $id"
    echo "Logs:      $self logs $id"
    echo "Cancel:    $self cancel $id"
}

cmd_cancel() {
    require_jq
    require_inbox

    [[ $# -eq 1 ]] || die "Usage: aoc-schedule cancel <job-id>"
    valid_id "$1" || die "Invalid job id: $1"

    local target_id="$1"
    local id created_at
    id="$(new_id)"
    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    jq -n \
        --arg id "$id" \
        --arg action "cancel" \
        --arg target_id "$target_id" \
        --arg created_at "$created_at" \
        --arg requested_by "$(whoami 2>/dev/null || echo dev)" \
        '{
            version: 1,
            id: $id,
            action: $action,
            target_id: $target_id,
            created_at: $created_at,
            requested_by: $requested_by
        }' | write_request "$id"

    echo "Cancel requested: $target_id"
    echo "Request id:       $id"
}

cmd_list() {
    require_jq

    [[ -d "$STATUS_DIR" ]] || die "Schedule status directory not found at $STATUS_DIR"

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

cmd_status() {
    require_jq
    [[ $# -eq 1 ]] || die "Usage: aoc-schedule status <job-id>"
    valid_id "$1" || die "Invalid job id: $1"

    local file="$STATUS_DIR/$1.json"
    if [[ -f "$file" ]]; then
        jq . "$file"
        return 0
    fi

    if [[ -f "$INBOX_DIR/$1.json" ]]; then
        echo "Request is still queued in the container inbox."
        jq . "$INBOX_DIR/$1.json"
        return 0
    fi

    die "No status found for job: $1"
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
        cron)
            shift
            cmd_cron "$@"
            ;;
        cancel)
            shift
            cmd_cancel "$@"
            ;;
        list|"")
            [[ -z "$cmd" ]] || shift
            cmd_list
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
