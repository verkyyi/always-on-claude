#!/bin/bash
# Tests for scripts/runtime/schedule-v2-runner.sh

RUNNER="$REPO_ROOT/scripts/runtime/schedule-v2-runner.sh"

setup() {
    mkdir -p \
        "$TEST_DIR/schedule/jobs" \
        "$TEST_DIR/schedule/status" \
        "$TEST_DIR/schedule/logs" \
        "$TEST_DIR/schedule/runs" \
        "$TEST_DIR/schedule/locks"
    export AOC_SCHEDULE_DIR="$TEST_DIR/schedule"

    cat > "$TEST_DIR/bin/docker" <<'EOF'
#!/bin/bash
if [[ "$1" == "compose" ]]; then
    shift
fi
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|exec|-T|-w)
            if [[ "$1" == "-f" || "$1" == "-w" ]]; then
                shift 2
            else
                shift
            fi
            ;;
        dev)
            shift
            ;;
        bash)
            shift
            if [[ "${1:-}" == "-lc" ]]; then
                shift
            fi
            exec bash -lc "$1"
            ;;
        *)
            shift
            ;;
    esac
done
exit 1
EOF
    chmod +x "$TEST_DIR/bin/docker"
}

test_runner_executes_slot_and_writes_status() {
    cat > "$TEST_DIR/schedule/jobs/job1.json" <<'EOF'
{
  "version": 2,
  "id": "job1",
  "label": "job-one",
  "timezone": "America/Los_Angeles",
  "schedule": {"type":"hourly","minute":0},
  "cwd": "/home/dev/projects/app",
  "command": "echo ok",
  "container_service": "dev",
  "enabled": true,
  "timeout_sec": 30
}
EOF

    AOC_DOCKER="docker" bash "$RUNNER" --job-id job1 --slot 2026-04-25T11:00 --mode scheduled

    assert_eq "succeeded" "$(jq -r '.status' "$TEST_DIR/schedule/runs/job1/2026-04-25T11:00.json")"
    assert_eq "scheduled" "$(jq -r '.status' "$TEST_DIR/schedule/status/job1.json")"
    assert_eq "2026-04-25T11:00" "$(jq -r '.last_successful_slot' "$TEST_DIR/schedule/status/job1.json")"
    assert_contains "$(cat "$TEST_DIR/schedule/logs/job1.log")" "job job1 slot 2026-04-25T11:00"
}

test_runner_noops_for_completed_slot() {
    cat > "$TEST_DIR/schedule/jobs/job2.json" <<'EOF'
{
  "version": 2,
  "id": "job2",
  "label": "job-two",
  "timezone": "America/Los_Angeles",
  "schedule": {"type":"daily","hour":3,"minute":0},
  "cwd": "/home/dev/projects/app",
  "command": "echo should-not-run > '$HOME/ran'",
  "container_service": "dev",
  "enabled": true
}
EOF
    mkdir -p "$TEST_DIR/schedule/runs/job2"
    cat > "$TEST_DIR/schedule/runs/job2/2026-04-25T03:00.json" <<'EOF'
{"job_id":"job2","slot":"2026-04-25T03:00","status":"succeeded"}
EOF

    bash "$RUNNER" --job-id job2 --slot 2026-04-25T03:00 --mode scheduled > "$TEST_DIR/output"

    assert_contains "$(cat "$TEST_DIR/output")" "slot already completed"
    assert_file_not_exists "$HOME/ran"
}
