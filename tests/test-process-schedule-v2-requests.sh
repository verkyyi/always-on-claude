#!/bin/bash
# Tests for scripts/runtime/process-schedule-v2-requests.sh

PROCESSOR="$REPO_ROOT/scripts/runtime/process-schedule-v2-requests.sh"

setup() {
    mkdir -p "$TEST_DIR/schedule/inbox-v2" "$TEST_DIR/schedule/request-status" "$TEST_DIR/schedule/jobs" "$TEST_DIR/schedule/status" "$TEST_DIR/schedule/logs" "$TEST_DIR/schedule/runs" "$TEST_DIR/schedule/locks"
    cat > "$TEST_DIR/manage-stub.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "$@" >> "$TEST_DIR/manage.log"
EOF
    chmod +x "$TEST_DIR/manage-stub.sh"
}

test_create_request_writes_job_and_marks_success() {
    cat > "$TEST_DIR/schedule/inbox-v2/request-1.json" <<'EOF'
{
  "version": 2,
  "request_id": "request-1",
  "action": "create",
  "job": {
    "version": 2,
    "id": "dashboard-hourly",
    "label": "dashboard-hourly",
    "timezone": "America/Los_Angeles",
    "schedule": {"type":"hourly","minute":0},
    "grace_window_sec": 7200,
    "cwd": "/home/dev/projects/app",
    "command": "./dashboard/hourly.sh",
    "container_service": "dev",
    "compose_file": "docker-compose.macmini.yml",
    "timeout_sec": 1200,
    "enabled": true
  }
}
EOF

    AOC_SCHEDULE_DIR="$TEST_DIR/schedule" TEST_DIR="$TEST_DIR" AOC_SCHEDULE_V2_MANAGE="$TEST_DIR/manage-stub.sh" bash "$PROCESSOR"

    assert_file_exists "$TEST_DIR/schedule/jobs/dashboard-hourly.json"
    assert_eq "hourly" "$(jq -r '.schedule.type' "$TEST_DIR/schedule/jobs/dashboard-hourly.json")"
    assert_contains "$(cat "$TEST_DIR/manage.log")" "install-job dashboard-hourly"
    assert_eq "succeeded" "$(jq -r '.status' "$TEST_DIR/schedule/request-status/request-1.json")"
}

test_invalid_request_marks_failure() {
    cat > "$TEST_DIR/schedule/inbox-v2/request-bad.json" <<'EOF'
{"version":2,"request_id":"request-bad","action":"create","job":{"id":"bad","cwd":"/tmp"}}
EOF

    AOC_SCHEDULE_DIR="$TEST_DIR/schedule" TEST_DIR="$TEST_DIR" AOC_SCHEDULE_V2_MANAGE="$TEST_DIR/manage-stub.sh" bash "$PROCESSOR"

    assert_eq "failed" "$(jq -r '.status' "$TEST_DIR/schedule/request-status/request-bad.json")"
    assert_file_not_exists "$TEST_DIR/schedule/jobs/bad.json"
}

test_invalid_timezone_marks_failure() {
    cat > "$TEST_DIR/schedule/inbox-v2/request-tz.json" <<'EOF'
{
  "version": 2,
  "request_id": "request-tz",
  "action": "create",
  "job": {
    "version": 2,
    "id": "bad-tz",
    "label": "bad-tz",
    "timezone": "PDT",
    "schedule": {"type":"hourly","minute":0},
    "grace_window_sec": 7200,
    "cwd": "/home/dev/projects/app",
    "command": "./hourly.sh",
    "enabled": true
  }
}
EOF

    AOC_SCHEDULE_DIR="$TEST_DIR/schedule" TEST_DIR="$TEST_DIR" AOC_SCHEDULE_V2_MANAGE="$TEST_DIR/manage-stub.sh" bash "$PROCESSOR"

    assert_eq "failed" "$(jq -r '.status' "$TEST_DIR/schedule/request-status/request-tz.json")"
    assert_file_not_exists "$TEST_DIR/schedule/jobs/bad-tz.json"
}

test_disable_request_updates_job_and_uninstalls() {
    cat > "$TEST_DIR/schedule/jobs/nightly.json" <<'EOF'
{"version":2,"id":"nightly","label":"nightly","timezone":"America/Los_Angeles","schedule":{"type":"daily","hour":3,"minute":0},"grace_window_sec":7200,"cwd":"/home/dev/projects/app","command":"./nightly.sh","enabled":true}
EOF
    cat > "$TEST_DIR/schedule/inbox-v2/request-disable.json" <<'EOF'
{"version":2,"request_id":"request-disable","action":"disable","job_id":"nightly"}
EOF

    AOC_SCHEDULE_DIR="$TEST_DIR/schedule" TEST_DIR="$TEST_DIR" AOC_SCHEDULE_V2_MANAGE="$TEST_DIR/manage-stub.sh" bash "$PROCESSOR"

    assert_eq "false" "$(jq -r '.enabled' "$TEST_DIR/schedule/jobs/nightly.json")"
    assert_contains "$(cat "$TEST_DIR/manage.log")" "uninstall-job nightly"
}
