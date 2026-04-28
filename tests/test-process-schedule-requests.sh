#!/bin/bash
# Tests for scripts/runtime/process-schedule-requests.sh

PROCESSOR_SCRIPT="$REPO_ROOT/scripts/runtime/process-schedule-requests.sh"

setup() {
    mkdir -p \
        "$TEST_DIR/schedule/inbox" \
        "$TEST_DIR/schedule/processing" \
        "$TEST_DIR/schedule/jobs" \
        "$TEST_DIR/schedule/logs" \
        "$TEST_DIR/schedule/status" \
        "$TEST_DIR/schedule/run" \
        "$TEST_DIR/dev-env" \
        "$HOME/projects/app"

    cat > "$TEST_DIR/bin/docker" <<'EOF'
#!/bin/bash
last_arg="${@: -1}"
bash -lc "$last_arg"
EOF
    chmod +x "$TEST_DIR/bin/docker"
}

wait_for_file() {
    local path="$1"
    local attempts="${2:-50}"
    local i

    for ((i = 0; i < attempts; i++)); do
        [[ -e "$path" ]] && return 0
        sleep 0.1
    done

    _fail "timed out waiting for file: $path"
}

wait_for_jq_value() {
    local file="$1"
    local jq_filter="$2"
    local expected="$3"
    local attempts="${4:-50}"
    local i value

    for ((i = 0; i < attempts; i++)); do
        if [[ -f "$file" ]]; then
            value="$(jq -r "$jq_filter" "$file" 2>/dev/null || true)"
            [[ "$value" == "$expected" ]] && return 0
        fi
        sleep 0.1
    done

    _fail "timed out waiting for $jq_filter == $expected in $file"
}

test_launchd_cron_dispatches_async() {
    local request status_file marker duration

    marker="$TEST_DIR/markers/cron-ran"
    request="$TEST_DIR/schedule/inbox/jobcron.json"
    status_file="$TEST_DIR/schedule/status/jobcron.json"

    jq -n \
        --arg id "jobcron" \
        --arg schedule "* * * * *" \
        --arg cwd "/home/dev/projects/app" \
        --arg command "sleep 3; : > '$marker'" \
        '{
            version: 1,
            id: $id,
            action: "cron",
            schedule: $schedule,
            cwd: $cwd,
            command: $command,
            created_at: "2026-04-25T18:00:00Z"
        }' > "$request"

    SECONDS=0
    AOC_USER="$(id -un)" \
    DEV_ENV="$TEST_DIR/dev-env" \
    AOC_SCHEDULE_DIR="$TEST_DIR/schedule" \
    AOC_DOCKER="docker" \
    AOC_HOST_PROJECTS_DIR="$HOME/projects" \
    AOC_AT_BACKEND="launchd" \
    AOC_CRON_BACKEND="launchd" \
    AOC_JOB_TIMEOUT_SEC="30" \
        bash "$PROCESSOR_SCRIPT"
    duration=$SECONDS

    [[ "$duration" -lt 3 ]] || _fail "processor should return before the job finishes"

    wait_for_file "$marker" 60
    wait_for_jq_value "$status_file" '.last_run_status // empty' "succeeded" 60
    assert_eq "0" "$(jq -r '.last_exit_code' "$status_file")"
    assert_eq "idle" "$(jq -r '.state' "$TEST_DIR/schedule/bridge-health.json")"
}

test_launchd_at_job_times_out() {
    local request status_file

    request="$TEST_DIR/schedule/inbox/jobat.json"
    status_file="$TEST_DIR/schedule/status/jobat.json"

    jq -n \
        --arg id "jobat" \
        --arg cwd "/home/dev/projects/app" \
        --arg command "sleep 3" \
        '{
            version: 1,
            id: $id,
            action: "at",
            time: "now",
            cwd: $cwd,
            command: $command,
            created_at: "2026-04-25T18:00:00Z"
        }' > "$request"

    AOC_USER="$(id -un)" \
    DEV_ENV="$TEST_DIR/dev-env" \
    AOC_SCHEDULE_DIR="$TEST_DIR/schedule" \
    AOC_DOCKER="docker" \
    AOC_HOST_PROJECTS_DIR="$HOME/projects" \
    AOC_AT_BACKEND="launchd" \
    AOC_CRON_BACKEND="launchd" \
    AOC_JOB_TIMEOUT_SEC="1" \
        bash "$PROCESSOR_SCRIPT"

    wait_for_jq_value "$status_file" '.status // empty' "failed" 60
    assert_eq "124" "$(jq -r '.exit_code' "$status_file")"
}

test_reconciles_stale_running_cron_and_rebuilds_job_script() {
    local status_file job_script

    status_file="$TEST_DIR/schedule/status/jobstale.json"
    job_script="$TEST_DIR/schedule/jobs/jobstale.sh"

    cat > "$status_file" <<'EOF'
{
  "version": 1,
  "id": "jobstale",
  "action": "cron",
  "schedule": "* * * * *",
  "cwd": "/home/dev/projects/app",
  "command": "echo rebuilt",
  "status": "running",
  "updated_at": "2026-04-25T18:00:00Z",
  "last_started_at": "2026-04-25T18:00:00Z",
  "worker_pid": 999999
}
EOF

    cat > "$job_script" <<'EOF'
#!/bin/bash
echo old-script
EOF
    chmod +x "$job_script"

    AOC_USER="$(id -un)" \
    DEV_ENV="$TEST_DIR/dev-env" \
    AOC_SCHEDULE_DIR="$TEST_DIR/schedule" \
    AOC_DOCKER="docker" \
    AOC_HOST_PROJECTS_DIR="$HOME/projects" \
    AOC_AT_BACKEND="launchd" \
    AOC_CRON_BACKEND="launchd" \
        bash "$PROCESSOR_SCRIPT"

    assert_eq "scheduled" "$(jq -r '.status' "$status_file")"
    assert_eq "failed" "$(jq -r '.last_run_status' "$status_file")"
    assert_eq "125" "$(jq -r '.last_exit_code' "$status_file")"
    assert_contains "$(cat "$job_script")" 'JOB_TIMEOUT_SEC='
}
