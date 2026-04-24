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
    local pct="$1" size="${2:-200000}" model="${3:-claude-opus-4-6}" cwd="${4:-}"
    jq -n \
        --argjson pct "$pct" \
        --argjson size "$size" \
        --arg model "$model" \
        --arg cwd "$cwd" \
        '{
            context_window: {
                remaining_percentage: $pct,
                context_window_size: $size
            },
            model: {id: $model}
        } + (if $cwd == "" then {} else {workspace: {current_dir: $cwd}} end)'
}

_hash_path() {
    if command -v md5sum >/dev/null 2>&1; then
        printf '%s' "$1" | md5sum | awk '{print $1}'
    elif command -v md5 >/dev/null 2>&1; then
        printf '%s' "$1" | md5 -q
    else
        printf '%s' "$1" | cksum | awk '{print $1}'
    fi
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

test_shows_git_branch_and_cached_repo_counts() {
    local repo branch hash cache_dir output
    repo=$(create_test_repo statusline-repo)
    repo=$(git -C "$repo" rev-parse --show-toplevel)
    branch=$(git -C "$repo" branch --show-current)
    hash=$(_hash_path "$repo")
    cache_dir="$HOME/.claude/cache/repo-status"
    mkdir -p "$cache_dir"
    {
        printf 'repo=%s\n' "$repo"
        printf 'issues=3\n'
        printf 'prs=2\n'
        printf 'ts=%s\n' "$(date +%s)"
    } > "$cache_dir/${hash}.txt"

    output=$(_run_statusline "$(_make_json 50 200000 "claude-opus-4-6" "$repo")")

    assert_contains "$output" "$branch"
    assert_contains "$output" "3i"
    assert_contains "$output" "2p"
}

test_handles_empty_input() {
    local exit_code=0
    echo "" | bash "$STATUSLINE_SCRIPT" >/dev/null 2>&1 || exit_code=$?
    assert_eq "0" "$exit_code"
}
