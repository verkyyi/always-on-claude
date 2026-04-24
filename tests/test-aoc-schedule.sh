#!/bin/bash
# Tests for scripts/runtime/aoc-schedule.sh

SCHEDULE_SCRIPT="$REPO_ROOT/scripts/runtime/aoc-schedule.sh"

setup() {
    mkdir -p "$TEST_DIR/schedule/inbox" "$TEST_DIR/schedule/status" "$TEST_DIR/schedule/logs"
}

test_at_writes_request_json() {
    local output request id command cwd

    output=$(AOC_SCHEDULE_DIR="$TEST_DIR/schedule" bash "$SCHEDULE_SCRIPT" \
        at "now + 1 hour" --cwd /home/dev/projects/app -- "echo hello")

    assert_contains "$output" "Submitted:"

    request=$(find "$TEST_DIR/schedule/inbox" -name '*.json' -type f | head -1)
    assert_file_exists "$request"

    id=$(jq -r '.id' "$request")
    command=$(jq -r '.command' "$request")
    cwd=$(jq -r '.cwd' "$request")

    [[ "$id" =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]+$ ]] || _fail "unexpected id: $id"
    assert_eq "echo hello" "$command"
    assert_eq "/home/dev/projects/app" "$cwd"
    assert_eq "at" "$(jq -r '.action' "$request")"
}

test_at_rejects_cwd_outside_projects() {
    assert_exit_code 1 env AOC_SCHEDULE_DIR="$TEST_DIR/schedule" bash "$SCHEDULE_SCRIPT" \
        at "now + 1 hour" --cwd /tmp -- "echo no"
}

test_cron_writes_request_json() {
    local request

    AOC_SCHEDULE_DIR="$TEST_DIR/schedule" bash "$SCHEDULE_SCRIPT" \
        cron "0 3 * * *" --cwd /home/dev/projects/app -- "npm test" >/dev/null

    request=$(find "$TEST_DIR/schedule/inbox" -name '*.json' -type f | head -1)
    assert_file_exists "$request"
    assert_eq "cron" "$(jq -r '.action' "$request")"
    assert_eq "0 3 * * *" "$(jq -r '.schedule' "$request")"
    assert_eq "npm test" "$(jq -r '.command' "$request")"
}

test_cron_rejects_invalid_spec() {
    assert_exit_code 1 env AOC_SCHEDULE_DIR="$TEST_DIR/schedule" bash "$SCHEDULE_SCRIPT" \
        cron "0 3 * *" --cwd /home/dev/projects/app -- "npm test"
}

test_list_reads_status_files() {
    cat > "$TEST_DIR/schedule/status/job1.json" <<'EOF'
{"id":"job1","status":"scheduled","time":"03:00 tomorrow","command":"npm test","updated_at":"2026-04-24T04:00:00Z"}
EOF

    local output
    output=$(AOC_SCHEDULE_DIR="$TEST_DIR/schedule" bash "$SCHEDULE_SCRIPT" list)

    assert_contains "$output" "job1"
    assert_contains "$output" "scheduled"
    assert_contains "$output" "npm test"
}

test_cancel_writes_cancel_request() {
    local request

    AOC_SCHEDULE_DIR="$TEST_DIR/schedule" bash "$SCHEDULE_SCRIPT" cancel job1 >/dev/null

    request=$(find "$TEST_DIR/schedule/inbox" -name '*.json' -type f | head -1)
    assert_file_exists "$request"
    assert_eq "cancel" "$(jq -r '.action' "$request")"
    assert_eq "job1" "$(jq -r '.target_id' "$request")"
}
