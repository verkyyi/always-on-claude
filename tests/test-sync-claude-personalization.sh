#!/bin/bash
# Tests for scripts/runtime/sync-claude-personalization.sh

SYNC_SCRIPT="$REPO_ROOT/scripts/runtime/sync-claude-personalization.sh"

test_syncs_user_scope_schedule_command() {
    local first_output second_output

    first_output=$(CLAUDE_HOME="$HOME/.claude" bash "$SYNC_SCRIPT")
    second_output=$(CLAUDE_HOME="$HOME/.claude" bash "$SYNC_SCRIPT")

    assert_eq "updated" "$first_output"
    assert_eq "unchanged" "$second_output"
    assert_file_exists "$HOME/.claude/commands/schedule.md"
    assert_file_exists "$HOME/.claude/commands/host-schedule.md"
    assert_file_exists "$HOME/.claude/skills/host-schedule/SKILL.md"
    assert_file_exists "$HOME/.claude/hooks/repo-counts-refresh.sh"
    assert_file_exists "$HOME/.claude/hooks/session-git-context.sh"
    assert_contains "$(cat "$HOME/.claude/commands/schedule.md")" "aoc-schedule.sh"
    assert_contains "$(cat "$HOME/.claude/commands/host-schedule.md")" "aoc-schedule.sh"
    assert_contains "$(cat "$HOME/.claude/skills/host-schedule/SKILL.md")" "aoc-schedule.sh"
    [[ -x "$HOME/.claude/hooks/repo-counts-refresh.sh" ]] || _fail "repo-counts-refresh.sh should be executable"
    [[ -x "$HOME/.claude/hooks/session-git-context.sh" ]] || _fail "session-git-context.sh should be executable"
}
