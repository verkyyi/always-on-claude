#!/bin/bash
# Tests for scripts/runtime/aoc-schedule.sh

SCHEDULE_SCRIPT="$REPO_ROOT/scripts/runtime/aoc-schedule.sh"

setup() {
    mkdir -p "$TEST_DIR/schedule/inbox-v2" "$TEST_DIR/schedule/request-status" "$TEST_DIR/schedule/status" "$TEST_DIR/schedule/logs" "$TEST_DIR/schedule/jobs"
}

test_daily_writes_v2_create_request() {
    local output request id

    output=$(AOC_SCHEDULE_DIR="$TEST_DIR/schedule" bash "$SCHEDULE_SCRIPT" \
        daily --time 03:00 --cwd /home/dev/projects/app --label nightly -- ./scripts/nightly.sh)

    assert_contains "$output" "Submitted:"
    assert_contains "$output" "Job:       nightly"

    request=$(find "$TEST_DIR/schedule/inbox-v2" -name '*.json' -type f | head -1)
    assert_file_exists "$request"

    assert_eq "2" "$(jq -r '.version' "$request")"
    assert_eq "create" "$(jq -r '.action' "$request")"
    assert_eq "nightly" "$(jq -r '.job.id' "$request")"
    assert_eq "daily" "$(jq -r '.job.schedule.type' "$request")"
    assert_eq "3" "$(jq -r '.job.schedule.hour' "$request")"
    assert_eq "0" "$(jq -r '.job.schedule.minute' "$request")"
    assert_eq "/home/dev/projects/app" "$(jq -r '.job.cwd' "$request")"
    assert_eq "./scripts/nightly.sh" "$(jq -r '.job.command' "$request")"
}

test_at_writes_once_request() {
    local request

    AOC_SCHEDULE_DIR="$TEST_DIR/schedule" bash "$SCHEDULE_SCRIPT" \
        at "2026-04-26 09:00" --cwd /home/dev/projects/app -- "echo hello" >/dev/null

    request=$(find "$TEST_DIR/schedule/inbox-v2" -name '*.json' -type f | head -1)
    assert_file_exists "$request"
    assert_eq "once" "$(jq -r '.job.schedule.type' "$request")"
    assert_eq "2026-04-26 09:00" "$(jq -r '.job.schedule.local_time' "$request")"
}

test_hourly_rejects_invalid_minute() {
    assert_exit_code 1 env AOC_SCHEDULE_DIR="$TEST_DIR/schedule" bash "$SCHEDULE_SCRIPT" \
        hourly --minute 90 --cwd /home/dev/projects/app -- "echo no"
}

test_rejects_cwd_outside_projects() {
    assert_exit_code 1 env AOC_SCHEDULE_DIR="$TEST_DIR/schedule" bash "$SCHEDULE_SCRIPT" \
        daily --time 03:00 --cwd /tmp -- "echo no"
}

test_delete_writes_request() {
    local request

    AOC_SCHEDULE_DIR="$TEST_DIR/schedule" bash "$SCHEDULE_SCRIPT" delete nightly >/dev/null

    request=$(find "$TEST_DIR/schedule/inbox-v2" -name '*.json' -type f | head -1)
    assert_file_exists "$request"
    assert_eq "delete" "$(jq -r '.action' "$request")"
    assert_eq "nightly" "$(jq -r '.job_id' "$request")"
}

test_list_reads_v2_jobs() {
    cat > "$TEST_DIR/schedule/jobs/dashboard-hourly.json" <<'EOF'
{"id":"dashboard-hourly","label":"dashboard-hourly","timezone":"America/Los_Angeles","schedule":{"type":"hourly","minute":0},"enabled":true}
EOF
    cat > "$TEST_DIR/schedule/status/dashboard-hourly.json" <<'EOF'
{"id":"dashboard-hourly","status":"scheduled","updated_at":"2026-04-25T13:00:07-0700"}
EOF

    local output
    output=$(AOC_SCHEDULE_DIR="$TEST_DIR/schedule" bash "$SCHEDULE_SCRIPT" list)

    assert_contains "$output" "dashboard-hourly"
    assert_contains "$output" "scheduled"
    assert_contains "$output" "hourly @ :00"
}

test_status_reads_request_status() {
    cat > "$TEST_DIR/schedule/request-status/request-1.json" <<'EOF'
{"request_id":"request-1","status":"succeeded","action":"create","job_id":"nightly"}
EOF

    local output
    output=$(AOC_SCHEDULE_DIR="$TEST_DIR/schedule" bash "$SCHEDULE_SCRIPT" status request-1)

    assert_contains "$output" '"status": "succeeded"'
    assert_contains "$output" '"job_id": "nightly"'
}

test_health_reads_bridge_health_file() {
    cat > "$TEST_DIR/schedule/bridge-health.json" <<'EOF'
{"state":"idle","last_recovery_check_at":"2026-04-25T18:30:00Z","active_jobs":0}
EOF

    local output
    output=$(AOC_SCHEDULE_DIR="$TEST_DIR/schedule" bash "$SCHEDULE_SCRIPT" health)

    assert_contains "$output" '"state": "idle"'
    assert_contains "$output" '"active_jobs": 0'
}
