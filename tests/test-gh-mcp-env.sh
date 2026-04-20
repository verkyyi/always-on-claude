#!/bin/bash
# Tests for scripts/runtime/gh-mcp-env.sh

GH_MCP_ENV_SCRIPT="$REPO_ROOT/scripts/runtime/gh-mcp-env.sh"

# Run the script in a subshell that:
#   - starts from a clean env (no GITHUB_PERSONAL_ACCESS_TOKEN)
#   - has PATH=$TEST_DIR/bin (no real gh leaks in)
# Prints: <token-or-UNSET> on stdout, preserves script stderr
_run_env_script() {
    (
        unset GITHUB_PERSONAL_ACCESS_TOKEN
        export PATH="$TEST_DIR/bin"
        source "$GH_MCP_ENV_SCRIPT" 2>"$TEST_DIR/stderr"
        echo "${GITHUB_PERSONAL_ACCESS_TOKEN:-UNSET}"
    )
}

_stderr() {
    cat "$TEST_DIR/stderr" 2>/dev/null || true
}

test_gh_missing_no_export_with_hint() {
    # No gh binary on PATH (TEST_DIR/bin is empty)
    local result
    result=$(_run_env_script)
    assert_eq "UNSET" "$result"
    assert_contains "$(_stderr)" "GitHub MCP inactive"
    assert_contains "$(_stderr)" "gh auth login"
}

test_gh_installed_but_unauthed_no_export_with_hint() {
    # gh exists but `gh auth status` exits non-zero
    cat > "$TEST_DIR/bin/gh" <<'MOCK'
#!/bin/bash
case "$1 $2" in
    "auth status") echo "not logged in" >&2; exit 1 ;;
    *) exit 1 ;;
esac
MOCK
    chmod +x "$TEST_DIR/bin/gh"

    local result
    result=$(_run_env_script)
    assert_eq "UNSET" "$result"
    assert_contains "$(_stderr)" "GitHub MCP inactive"
}

test_gh_authed_exports_token_silently() {
    # gh is authed and `gh auth token` prints a token
    cat > "$TEST_DIR/bin/gh" <<'MOCK'
#!/bin/bash
case "$1 $2" in
    "auth status") exit 0 ;;
    "auth token") echo "gho_testtoken123" ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "$TEST_DIR/bin/gh"

    local result
    result=$(_run_env_script)
    assert_eq "gho_testtoken123" "$result"
    # Hint must NOT appear when MCP successfully activates
    local stderr
    stderr=$(_stderr)
    if [[ "$stderr" == *"GitHub MCP inactive"* ]]; then
        _fail "stderr unexpectedly contained hint: $stderr"
    fi
}
