#!/bin/bash
# Tests for scripts/runtime/schedule-v2-manage.sh

MANAGE="$REPO_ROOT/scripts/runtime/schedule-v2-manage.sh"

setup() {
    export TEST_DIR
    mkdir -p \
        "$TEST_DIR/schedule/jobs" \
        "$TEST_DIR/schedule/status" \
        "$TEST_DIR/schedule/logs" \
        "$TEST_DIR/schedule/runs" \
        "$TEST_DIR/schedule/locks" \
        "$TEST_DIR/bin" \
        "$HOME/Library/LaunchAgents"
    export AOC_SCHEDULE_DIR="$TEST_DIR/schedule"
    export DEV_ENV="$REPO_ROOT"

    cat > "$TEST_DIR/bin/launchctl" <<'EOF'
#!/bin/bash
echo "$0 $*" >> "$TEST_DIR/launchctl.log"
exit 0
EOF
    cat > "$TEST_DIR/bin/plutil" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$TEST_DIR/bin/launchctl" "$TEST_DIR/bin/plutil"
}

test_install_job_generates_launchd_plist() {
    cat > "$TEST_DIR/schedule/jobs/job1.json" <<'EOF'
{
  "version": 2,
  "id": "job1",
  "label": "job-one",
  "timezone": "America/Los_Angeles",
  "schedule": {"type":"daily","hour":3,"minute":0},
  "grace_window_sec": 7200,
  "cwd": "/home/dev/projects/app",
  "command": "echo hi",
  "container_service": "dev",
  "compose_file": "docker-compose.macmini.yml",
  "enabled": true
}
EOF

    PATH="$TEST_DIR/bin:$PATH" bash "$MANAGE" install-job job1 >/dev/null

    local plist="$TEST_DIR/schedule/native/macos/com.always-on-claude.schedule.job1.plist"
    assert_file_exists "$plist"
    assert_contains "$(cat "$plist")" "schedule-v2-run-scheduled.sh"
    assert_contains "$(cat "$plist")" "<key>Hour</key><integer>3</integer>"
    assert_contains "$(cat "$TEST_DIR/launchctl.log")" "bootstrap"
}

test_install_daily_hours_job_generates_launchd_array() {
    cat > "$TEST_DIR/schedule/jobs/job2.json" <<'EOF'
{
  "version": 2,
  "id": "job2",
  "label": "job-two",
  "timezone": "America/Los_Angeles",
  "schedule": {"type":"daily_hours","hours":[0,3,6,9,12,15,18,21],"minute":0},
  "grace_window_sec": 7200,
  "cwd": "/home/dev/projects/app",
  "command": "echo hi",
  "container_service": "dev",
  "compose_file": "docker-compose.macmini.yml",
  "enabled": true
}
EOF

    PATH="$TEST_DIR/bin:$PATH" bash "$MANAGE" install-job job2 >/dev/null

    local plist="$TEST_DIR/schedule/native/macos/com.always-on-claude.schedule.job2.plist"
    assert_file_exists "$plist"
    assert_contains "$(cat "$plist")" "<array>"
    assert_contains "$(cat "$plist")" "<key>Hour</key><integer>21</integer>"
}
