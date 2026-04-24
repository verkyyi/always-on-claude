#!/bin/bash
# Tests for scripts/runtime/sync-codex-config.sh

SYNC_SCRIPT="$REPO_ROOT/scripts/runtime/sync-codex-config.sh"

setup() {
    mkdir -p "$HOME/.codex"
}

test_creates_config_with_full_permissions_defaults() {
    local output
    output=$(bash "$SYNC_SCRIPT")

    assert_eq "updated" "$output"
    assert_file_exists "$HOME/.codex/config.toml"

    local config
    config=$(cat "$HOME/.codex/config.toml")
    assert_contains "$config" 'approval_policy = "never"'
    assert_contains "$config" 'sandbox_mode = "danger-full-access"'
}

test_preserves_existing_tables_and_moves_defaults_to_top_level() {
    cat > "$HOME/.codex/config.toml" <<'EOF'
approvals_reviewer = "user"

[projects."/home/dev/projects/ainbox"]
trust_level = "trusted"

[plugins."github@openai-curated"]
enabled = true
approval_policy = "on-request"
sandbox_mode = "workspace-write"
EOF

    local output
    output=$(bash "$SYNC_SCRIPT")
    assert_eq "updated" "$output"

    local config
    config=$(cat "$HOME/.codex/config.toml")
    assert_contains "$config" $'approvals_reviewer = "user"\napproval_policy = "never"\nsandbox_mode = "danger-full-access"\n\n[projects."/home/dev/projects/ainbox"]'
    assert_contains "$config" $'[plugins."github@openai-curated"]\nenabled = true'
}

test_noop_when_defaults_already_present() {
    cat > "$HOME/.codex/config.toml" <<'EOF'
approval_policy = "never"
sandbox_mode = "danger-full-access"

[projects."/home/dev/projects/ainbox"]
trust_level = "trusted"
EOF

    local before output after
    before=$(cat "$HOME/.codex/config.toml")
    output=$(bash "$SYNC_SCRIPT")
    after=$(cat "$HOME/.codex/config.toml")

    assert_eq "unchanged" "$output"
    assert_eq "$before" "$after"
}
