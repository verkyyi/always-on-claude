#!/bin/bash
# Tests for scripts/runtime/statusline-command.sh

STATUSLINE_SCRIPT="$REPO_ROOT/scripts/runtime/statusline-command.sh"

setup() {
    mkdir -p "$HOME/.claude"
    echo '{"effortLevel": "high"}' > "$HOME/.claude/settings.json"
}

_run_statusline() {
    local json="$1"
    echo "$json" | bash "$STATUSLINE_SCRIPT" 2>/dev/null
}

_make_json() {
    local pct="$1" size="${2:-200000}" model="${3:-claude-opus-4-6}"
    cat <<JSON
{"context_window":{"remaining_percentage":$pct,"context_window_size":$size},"model":{"id":"$model"}}
JSON
}

test_parses_model_id() {
    local output
    output=$(_run_statusline "$(_make_json 50 200000 "claude-opus-4-6")")
    assert_contains "$output" "Opus"
}

test_color_green_at_31_plus() {
    local output
    output=$(_run_statusline "$(_make_json 50)")
    assert_contains "$output" $'\033[0;32m'
}

test_color_yellow_11_to_30() {
    local output
    output=$(_run_statusline "$(_make_json 20)")
    assert_contains "$output" $'\033[0;33m'
}

test_color_red_at_10_or_below() {
    local output
    output=$(_run_statusline "$(_make_json 5)")
    assert_contains "$output" $'\033[0;31m'
}

test_boundary_10_is_red() {
    local output
    output=$(_run_statusline "$(_make_json 10)")
    assert_contains "$output" $'\033[0;31m'
}

test_boundary_30_is_yellow() {
    local output
    output=$(_run_statusline "$(_make_json 30)")
    assert_contains "$output" $'\033[0;33m'
}

test_reads_effort_from_settings() {
    echo '{"effortLevel": "low"}' > "$HOME/.claude/settings.json"
    local output
    output=$(_run_statusline "$(_make_json 50)")
    assert_contains "$output" "low"
}

test_handles_empty_input() {
    local exit_code=0
    echo "" | bash "$STATUSLINE_SCRIPT" >/dev/null 2>&1 || exit_code=$?
    assert_eq "0" "$exit_code"
}
