#!/bin/bash
# Tests for scripts/runtime/schedule-v2-lib.sh

LIB="$REPO_ROOT/scripts/runtime/schedule-v2-lib.sh"

setup() {
    mkdir -p "$TEST_DIR/schedule/jobs" "$TEST_DIR/schedule/status" "$TEST_DIR/schedule/logs" "$TEST_DIR/schedule/runs" "$TEST_DIR/schedule/locks"
    export AOC_SCHEDULE_DIR="$TEST_DIR/schedule"
}

test_compute_hourly_slot() {
    cat > "$TEST_DIR/schedule/jobs/job1.json" <<'EOF'
{"id":"job1","timezone":"America/Los_Angeles","schedule":{"type":"hourly","minute":0},"cwd":"/home/dev/projects/app","command":"echo hi","enabled":true}
EOF

    local slot
    slot=$(bash -lc "source \"$LIB\"; schedule_v2_compute_slot \"$TEST_DIR/schedule/jobs/job1.json\" '2026-04-25T11:56:25-0700'")

    assert_eq "2026-04-25T11:00" "$slot"
}

test_compute_daily_slot_before_due_uses_previous_day() {
    cat > "$TEST_DIR/schedule/jobs/job2.json" <<'EOF'
{"id":"job2","timezone":"America/Los_Angeles","schedule":{"type":"daily","hour":3,"minute":0},"cwd":"/home/dev/projects/app","command":"echo hi","enabled":true}
EOF

    local slot
    slot=$(bash -lc "source \"$LIB\"; schedule_v2_compute_slot \"$TEST_DIR/schedule/jobs/job2.json\" '2026-04-25T02:30:00-0700'")

    assert_eq "2026-04-24T03:00" "$slot"
}

test_compute_weekly_slot() {
    cat > "$TEST_DIR/schedule/jobs/job3.json" <<'EOF'
{"id":"job3","timezone":"America/Los_Angeles","schedule":{"type":"weekly","weekday":"friday","hour":21,"minute":0},"cwd":"/home/dev/projects/app","command":"echo hi","enabled":true}
EOF

    local slot
    slot=$(bash -lc "source \"$LIB\"; schedule_v2_compute_slot \"$TEST_DIR/schedule/jobs/job3.json\" '2026-04-24T22:15:00-0700'")

    assert_eq "2026-04-24T21:00" "$slot"
}

test_compute_daily_hours_slot() {
    cat > "$TEST_DIR/schedule/jobs/job4.json" <<'EOF'
{"id":"job4","timezone":"America/Los_Angeles","schedule":{"type":"daily_hours","hours":[0,3,6,9,12,15,18,21],"minute":0},"cwd":"/home/dev/projects/app","command":"echo hi","enabled":true}
EOF

    local slot
    slot=$(bash -lc "source \"$LIB\"; schedule_v2_compute_slot \"$TEST_DIR/schedule/jobs/job4.json\" '2026-04-25T14:17:00-0700'")

    assert_eq "2026-04-25T12:00" "$slot"
}
