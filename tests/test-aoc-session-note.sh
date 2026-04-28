#!/bin/bash
# Tests for scripts/runtime/aoc-session-note.sh

NOTE_SCRIPT="$REPO_ROOT/scripts/runtime/aoc-session-note.sh"

setup() {
    mkdir -p "$HOME/projects"
}

test_requires_tmux() {
    unset TMUX
    assert_exit_code 1 bash "$NOTE_SCRIPT"
}

test_sets_note_for_current_session() {
    export TMUX=/tmp/tmux-sock
    export TMUX_LOG="$TEST_DIR/markers/tmux.log"

    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
echo "$*" >> "$TMUX_LOG"
if [[ "$1" == "display-message" ]]; then
    echo "claude-myrepo"
    exit 0
fi
if [[ "$1" == "set-option" ]]; then
    exit 0
fi
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/tmux"

    local output log
    output=$(bash "$NOTE_SCRIPT" "oauth fix")
    log=$(cat "$TMUX_LOG")

    assert_eq "oauth fix" "$output"
    assert_contains "$log" "display-message -p #S"
    assert_contains "$log" "set-option -t claude-myrepo -q @aoc_note oauth fix"
}

test_clears_note_for_current_session() {
    export TMUX=/tmp/tmux-sock
    export TMUX_LOG="$TEST_DIR/markers/tmux.log"

    cat > "$TEST_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
echo "$*" >> "$TMUX_LOG"
if [[ "$1" == "display-message" ]]; then
    echo "claude-myrepo"
    exit 0
fi
if [[ "$1" == "set-option" ]]; then
    exit 0
fi
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/tmux"

    local output log
    output=$(bash "$NOTE_SCRIPT" --clear)
    log=$(cat "$TMUX_LOG")

    assert_eq "cleared" "$output"
    assert_contains "$log" "set-option -t claude-myrepo -qu @aoc_note"
}
