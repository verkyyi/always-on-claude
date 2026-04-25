#!/bin/bash
# Tests for scripts/runtime/run-code-agent.sh

RUNNER_SCRIPT="$REPO_ROOT/scripts/runtime/run-code-agent.sh"
REAL_TTY_TIMEOUT_SECONDS=4

setup() {
    mkdir -p "$HOME/.claude" "$HOME/work"
}

test_claude_resume_latest_starts_fresh_session() {
    cat > "$TEST_DIR/bin/claude" <<MOCK
#!/bin/bash
printf '%s\n' "\$*" > "$HOME/claude.args"
MOCK
    chmod +x "$TEST_DIR/bin/claude"

    bash "$RUNNER_SCRIPT" --agent claude --cwd "$HOME/work" --resume-latest

    assert_eq "" "$(cat "$HOME/claude.args")"
}

test_claude_message_without_resume_passes_prompt() {
    cat > "$TEST_DIR/bin/claude" <<MOCK
#!/bin/bash
printf '%s\n' "\$*" > "$HOME/claude.args"
MOCK
    chmod +x "$TEST_DIR/bin/claude"

    bash "$RUNNER_SCRIPT" --agent claude --message "hello"

    assert_eq "hello" "$(cat "$HOME/claude.args")"
}

test_codex_resume_latest_uses_resume_last() {
    cat > "$TEST_DIR/bin/codex" <<MOCK
#!/bin/bash
printf '%s\n' "\$*" > "$HOME/codex.args"
MOCK
    chmod +x "$TEST_DIR/bin/codex"

    bash "$RUNNER_SCRIPT" --agent codex --cwd "$HOME/work" --resume-latest

    assert_eq "resume --last" "$(cat "$HOME/codex.args")"
}

test_codex_resume_latest_with_message_appends_prompt() {
    cat > "$TEST_DIR/bin/codex" <<MOCK
#!/bin/bash
printf '%s\n' "\$*" > "$HOME/codex.args"
MOCK
    chmod +x "$TEST_DIR/bin/codex"

    bash "$RUNNER_SCRIPT" --agent codex --resume-latest --message "hello"

    assert_eq "resume --last hello" "$(cat "$HOME/codex.args")"
}

test_claude_resume_latest_real_tty_stays_interactive() {
    [[ "${RUN_REAL_TTY_TESTS:-0}" == "1" ]] || skip_test "set RUN_REAL_TTY_TESTS=1 to enable real TTY checks"
    command -v claude >/dev/null 2>&1 || skip_test "claude not installed"
    command -v script >/dev/null 2>&1 || skip_test "script not installed"
    [[ -n "${_ORIG_HOME:-}" && -d "$_ORIG_HOME/.claude" ]] || skip_test "real Claude home not available"

    local output
    output=$(
        ORIG_HOME="$_ORIG_HOME" RUNNER_SCRIPT="$RUNNER_SCRIPT" REPO_ROOT="$REPO_ROOT" REAL_TTY_TIMEOUT_SECONDS="$REAL_TTY_TIMEOUT_SECONDS" \
        python3 - <<'PY'
import os
import shlex
import signal
import subprocess

repo = os.environ["REPO_ROOT"]
runner = os.environ["RUNNER_SCRIPT"]
home = os.environ["ORIG_HOME"]
timeout = int(os.environ["REAL_TTY_TIMEOUT_SECONDS"])
cmd = [
    "script",
    "-q",
    "/dev/null",
    "bash",
    "-lc",
    (
        f"export HOME={shlex.quote(home)}; "
        f"cd {shlex.quote(repo)} && "
        f"bash {shlex.quote(runner)} --agent claude --cwd {shlex.quote(repo)} --resume-latest"
    ),
]

proc = subprocess.Popen(
    cmd,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
    start_new_session=True,
)

try:
    out, _ = proc.communicate(timeout=timeout)
    print(f"EXIT {proc.returncode}")
    print(out[:12000])
except subprocess.TimeoutExpired:
    os.killpg(proc.pid, signal.SIGTERM)
    out, _ = proc.communicate(timeout=2)
    print("TIMEOUT")
    print(out[:12000])
PY
    )

    assert_contains "$output" "TIMEOUT" "expected Claude TTY launch to stay interactive, got: $output"
    [[ "$output" != *"sandbox.failIfUnavailable"* ]] || _fail "Claude TTY launch restored broken sandboxed resume path"
}
