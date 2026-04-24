#!/bin/bash
# Tests for scripts/deploy/setup-gmail-full.sh

SETUP_GMAIL_FULL_SCRIPT="$REPO_ROOT/scripts/deploy/setup-gmail-full.sh"

create_source_credentials() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/credentials.json" <<'EOF'
{"installed":{"client_id":"test-client"}}
EOF
    cat > "$dir/gcp-oauth.keys.json" <<'EOF'
{"refresh_token":"test-refresh"}
EOF
}

mock_claude_missing_server() {
    cat > "$TEST_DIR/bin/claude" <<EOF
#!/bin/bash
echo "\$*" >> "$TEST_DIR/claude.log"

if [[ "\$1 \$2 \$3" == "mcp get gmail-full" ]]; then
    exit 1
fi

if [[ "\$1 \$2" == "mcp add-json" ]]; then
    exit 0
fi

if [[ "\$1 \$2" == "mcp remove" ]]; then
    exit 0
fi

exit 0
EOF
    chmod +x "$TEST_DIR/bin/claude"
}

mock_claude_matching_server() {
    local credentials="$1"
    local oauth="$2"

    cat > "$TEST_DIR/bin/claude" <<EOF
#!/bin/bash
echo "\$*" >> "$TEST_DIR/claude.log"

if [[ "\$1 \$2 \$3" == "mcp get gmail-full" ]]; then
    cat <<'EOM'
gmail-full:
  Scope: User config (available in all your projects)
  Status: ✓ Connected
  Type: stdio
  Command: npx
  Args: @gongrzhe/server-gmail-autoauth-mcp
  Environment:
    GMAIL_CREDENTIALS_PATH=$credentials
    GMAIL_OAUTH_PATH=$oauth
EOM
    exit 0
fi

if [[ "\$1 \$2" == "mcp add-json" ]]; then
    exit 0
fi

if [[ "\$1 \$2" == "mcp remove" ]]; then
    exit 0
fi

exit 0
EOF
    chmod +x "$TEST_DIR/bin/claude"
}

test_defaults_to_local_target_and_preserves_existing_codex_config() {
    local source_dir output config
    source_dir="$HOME/source"
    create_source_credentials "$source_dir"

    mkdir -p "$HOME/.codex"
    cat > "$HOME/.codex/config.toml" <<'EOF'
approvals_reviewer = "user"

[plugins."github@openai-curated"]
enabled = true
EOF

    output=$(GMAIL_FULL_SOURCE_DIR="$source_dir" bash "$SETUP_GMAIL_FULL_SCRIPT")
    config=$(cat "$HOME/.codex/config.toml")

    assert_contains "$output" "STATUS: updated"
    assert_file_exists "$HOME/.gmail-mcp/credentials.json"
    assert_file_exists "$HOME/.gmail-mcp/gcp-oauth.keys.json"
    assert_contains "$config" 'approvals_reviewer = "user"'
    assert_contains "$config" $'[plugins."github@openai-curated"]\nenabled = true'
    assert_contains "$config" '[mcp_servers.gmail-full]'
    assert_contains "$config" 'GMAIL_CREDENTIALS_PATH = "'"$HOME"'/.gmail-mcp/credentials.json"'
    assert_contains "$config" 'GMAIL_OAUTH_PATH = "'"$HOME"'/.gmail-mcp/gcp-oauth.keys.json"'
}

test_uses_shared_codex_target_on_provisioned_hosts_and_registers_claude() {
    local source_dir output config claude_log
    source_dir="$HOME/source"
    create_source_credentials "$source_dir"
    mkdir -p "$HOME/dev-env"
    touch "$HOME/dev-env/.provisioned"
    mock_claude_missing_server

    output=$(GMAIL_FULL_SOURCE_DIR="$source_dir" bash "$SETUP_GMAIL_FULL_SCRIPT")
    config=$(cat "$HOME/.codex/config.toml")
    claude_log=$(cat "$TEST_DIR/claude.log")

    assert_contains "$output" "STATUS: updated"
    assert_file_exists "$HOME/.codex/gmail-mcp/credentials.json"
    assert_file_exists "$HOME/.codex/gmail-mcp/gcp-oauth.keys.json"
    assert_contains "$config" 'GMAIL_CREDENTIALS_PATH = "'"$HOME"'/.codex/gmail-mcp/credentials.json"'
    assert_contains "$config" 'GMAIL_OAUTH_PATH = "'"$HOME"'/.codex/gmail-mcp/gcp-oauth.keys.json"'
    assert_contains "$claude_log" 'mcp add-json -s user gmail-full'
}

test_is_idempotent_when_target_files_and_claude_registration_already_match() {
    local output config before after
    mkdir -p "$HOME/.gmail-mcp" "$HOME/.codex"

    cat > "$HOME/.gmail-mcp/credentials.json" <<'EOF'
{"installed":{"client_id":"test-client"}}
EOF
    cat > "$HOME/.gmail-mcp/gcp-oauth.keys.json" <<'EOF'
{"refresh_token":"test-refresh"}
EOF
    cat > "$HOME/.codex/config.toml" <<EOF
[mcp_servers.gmail-full]
command = "npx"
args = ["@gongrzhe/server-gmail-autoauth-mcp"]

[mcp_servers.gmail-full.env]
GMAIL_CREDENTIALS_PATH = "$HOME/.gmail-mcp/credentials.json"
GMAIL_OAUTH_PATH = "$HOME/.gmail-mcp/gcp-oauth.keys.json"

[mcp_servers.gmail-full.tools.search_emails]
approval_mode = "approve"
EOF

    mock_claude_matching_server "$HOME/.gmail-mcp/credentials.json" "$HOME/.gmail-mcp/gcp-oauth.keys.json"

    before=$(cat "$HOME/.codex/config.toml")
    output=$(bash "$SETUP_GMAIL_FULL_SCRIPT")
    after=$(cat "$HOME/.codex/config.toml")

    assert_contains "$output" "STATUS: unchanged"
    assert_eq "$before" "$after"
    assert_file_exists "$TEST_DIR/claude.log"
    assert_contains "$(cat "$TEST_DIR/claude.log")" 'mcp get gmail-full'
    if [[ "$(cat "$TEST_DIR/claude.log")" == *'mcp add-json -s user gmail-full'* ]]; then
        _fail "expected claude mcp add-json to be skipped"
    fi
}
