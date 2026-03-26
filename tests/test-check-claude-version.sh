#!/bin/bash
# Tests for scripts/runtime/check-claude-version.sh

VERSION_SCRIPT="$REPO_ROOT/scripts/runtime/check-claude-version.sh"

setup() {
    mkdir -p "$HOME/.claude"
}

# Helper: create a mock docker that returns a specific version
_mock_docker_version() {
    local version="$1"
    cat > "$TEST_DIR/bin/docker" <<MOCK
#!/bin/bash
if [[ "\$1" == "ps" ]]; then
    echo "claude-dev"
elif [[ "\$1" == "exec" ]]; then
    echo "$version (Claude Code)"
fi
MOCK
    chmod +x "$TEST_DIR/bin/docker"
}

# Helper: create a mock curl that returns a specific npm version
_mock_curl_version() {
    local version="$1"
    cat > "$TEST_DIR/bin/curl" <<MOCK
#!/bin/bash
echo '{"version":"$version"}'
MOCK
    chmod +x "$TEST_DIR/bin/curl"
}

# Helper: mock jq to extract version
_mock_jq() {
    cat > "$TEST_DIR/bin/jq" <<'MOCK'
#!/bin/bash
# Simple extraction of "version" from JSON
if [[ "$1" == "-r" ]]; then
    # Read stdin and extract version value
    sed -n 's/.*"version":"\([^"]*\)".*/\1/p'
fi
MOCK
    chmod +x "$TEST_DIR/bin/jq"
}

test_writes_current_when_versions_match() {
    _mock_docker_version "2.1.80"
    _mock_curl_version "2.1.80"
    _mock_jq

    bash "$VERSION_SCRIPT" 2>/dev/null || true

    assert_file_exists "$HOME/.claude-version-check"
    local content
    content=$(cat "$HOME/.claude-version-check")
    assert_contains "$content" "status=current"
    assert_contains "$content" "installed=2.1.80"
    assert_contains "$content" "latest=2.1.80"
}

test_writes_update_available_when_versions_differ() {
    _mock_docker_version "2.1.79"
    _mock_curl_version "2.1.80"
    _mock_jq

    bash "$VERSION_SCRIPT" 2>/dev/null || true

    assert_file_exists "$HOME/.claude-version-check"
    local content
    content=$(cat "$HOME/.claude-version-check")
    assert_contains "$content" "status=update-available"
    assert_contains "$content" "installed=2.1.79"
    assert_contains "$content" "latest=2.1.80"
}

test_exits_gracefully_when_no_container() {
    # docker ps returns nothing, no host claude either
    cat > "$TEST_DIR/bin/docker" <<'MOCK'
#!/bin/bash
if [[ "$1" == "ps" ]]; then
    echo ""
fi
MOCK
    chmod +x "$TEST_DIR/bin/docker"

    local exit_code=0
    bash "$VERSION_SCRIPT" 2>/dev/null || exit_code=$?
    assert_eq "0" "$exit_code" "should exit 0 when version unavailable"
}

test_exits_gracefully_when_npm_unreachable() {
    _mock_docker_version "2.1.80"
    # curl fails
    cat > "$TEST_DIR/bin/curl" <<'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$TEST_DIR/bin/curl"
    _mock_jq

    local exit_code=0
    bash "$VERSION_SCRIPT" 2>/dev/null || exit_code=$?
    assert_eq "0" "$exit_code" "should exit 0 when npm unreachable"
}

test_writes_log_file() {
    _mock_docker_version "2.1.80"
    _mock_curl_version "2.1.80"
    _mock_jq

    bash "$VERSION_SCRIPT" 2>/dev/null || true

    assert_file_exists "$HOME/.claude/claude-updates.log"
    local content
    content=$(cat "$HOME/.claude/claude-updates.log")
    assert_contains "$content" "Version check: installed=2.1.80 latest=2.1.80"
}

test_state_file_contains_checked_timestamp() {
    _mock_docker_version "2.1.80"
    _mock_curl_version "2.1.80"
    _mock_jq

    bash "$VERSION_SCRIPT" 2>/dev/null || true

    local content
    content=$(cat "$HOME/.claude-version-check")
    assert_contains "$content" "checked="
}
