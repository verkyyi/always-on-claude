#!/bin/bash
# Tests for scripts/runtime/claude-attention/hooks/guard.py — the PreToolUse
# deny-list that blocks catastrophic Bash commands in Claude sessions.
#
# This shim delegates to the guard's own case suite (tests/guard-cases.json, run
# by run-guard-tests.py), so any edit to guard.py that flips a BLOCK/ALLOW
# expectation fails CI. Add coverage by appending a case to that JSON — no need
# to touch this file.

GUARD_TEST_RUNNER="$REPO_ROOT/scripts/runtime/claude-attention/tests/run-guard-tests.py"

test_guard_case_suite_passes() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip_test "python3 not available"
        return
    fi
    assert_file_exists "$GUARD_TEST_RUNNER"

    local output rc=0
    output=$(python3 "$GUARD_TEST_RUNNER" 2>&1) || rc=$?
    # surface the FAIL lines so a broken guard is diagnosable in the CI log
    [[ $rc -eq 0 ]] || echo "$output" | sed 's/^/    /' >&2

    assert_eq 0 "$rc" "guard case suite reported failures"
    assert_contains "$output" "0 failed"
}
