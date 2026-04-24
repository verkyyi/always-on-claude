#!/bin/bash
# Tests for scripts/runtime/sync-codex-personalization.sh

SYNC_SCRIPT="$REPO_ROOT/scripts/runtime/sync-codex-personalization.sh"

setup() {
    mkdir -p "$HOME/.codex"
    mkdir -p "$HOME/projects"
}

test_syncs_home_state_and_repo_templates() {
    mkdir -p "$HOME/projects/ainbox" "$HOME/projects/agentfolio"

    cat > "$HOME/.codex/config.toml" <<'EOF'
approvals_reviewer = "user"

[plugins."github@openai-curated"]
enabled = true
EOF

    local output
    output=$(PROJECTS_DIR="$HOME/projects" bash "$SYNC_SCRIPT")
    assert_eq "updated" "$output"

    assert_file_exists "$HOME/.codex/AGENTS.md"
    assert_file_exists "$HOME/.codex/bin/fetch-mcp.sh"
    assert_file_exists "$HOME/.codex/bin/playwright-mcp.sh"
    assert_file_exists "$HOME/.codex/skills/futuapi/SKILL.md"
    assert_file_exists "$HOME/.codex/skills/install-futu-opend/SKILL.md"
    assert_file_exists "$HOME/.codex/skills/deploy-proxy/SKILL.md"
    assert_file_exists "$HOME/.codex/skills/release-plugin/SKILL.md"
    assert_file_exists "$HOME/projects/ainbox/.codex/config.toml"
    assert_file_exists "$HOME/projects/ainbox/.codex/hooks.json"
    assert_file_exists "$HOME/projects/agentfolio/.codex/config.toml"

    local agents config ainbox_config ainbox_hooks agentfolio_config
    agents=$(cat "$HOME/.codex/AGENTS.md")
    config=$(cat "$HOME/.codex/config.toml")
    ainbox_config=$(cat "$HOME/projects/ainbox/.codex/config.toml")
    ainbox_hooks=$(cat "$HOME/projects/ainbox/.codex/hooks.json")
    agentfolio_config=$(cat "$HOME/projects/agentfolio/.codex/config.toml")

    assert_contains "$agents" "Global AGENTS.md"
    assert_contains "$config" 'approval_policy = "never"'
    assert_contains "$config" 'sandbox_mode = "danger-full-access"'
    assert_contains "$config" $'[plugins."github@openai-curated"]\nenabled = true'
    assert_contains "$config" '[mcp_servers.context7]'
    assert_contains "$config" 'args = ["/home/dev/.codex/bin/fetch-mcp.sh"]'
    assert_contains "$config" '[mcp_servers.openaiDeveloperDocs]'
    assert_contains "$ainbox_config" 'project_doc_fallback_filenames = ["CLAUDE.md"]'
    assert_contains "$ainbox_config" '[features]'
    assert_contains "$ainbox_hooks" '"statusMessage": "Loading ainbox session context"'
    assert_contains "$agentfolio_config" 'project_doc_fallback_filenames = ["CLAUDE.md"]'
}

test_replaces_managed_sections_and_is_idempotent() {
    mkdir -p "$HOME/.codex/bin"

    cat > "$HOME/.codex/config.toml" <<'EOF'
approvals_reviewer = "user"

[mcp_servers.fetch]
command = "bash"
args = ["/tmp/old-fetch.sh"]

[projects."/tmp/foo"]
trust_level = "trusted"
EOF

    cat > "$HOME/.codex/bin/fetch-mcp.sh" <<'EOF'
#!/bin/bash
echo old
EOF

    local first_output second_output config
    first_output=$(PROJECTS_DIR="$HOME/projects" bash "$SYNC_SCRIPT")
    second_output=$(PROJECTS_DIR="$HOME/projects" bash "$SYNC_SCRIPT")
    config=$(cat "$HOME/.codex/config.toml")

    assert_eq "updated" "$first_output"
    assert_eq "unchanged" "$second_output"
    assert_contains "$config" 'args = ["/home/dev/.codex/bin/fetch-mcp.sh"]'
    assert_contains "$config" $'[projects."/tmp/foo"]\ntrust_level = "trusted"'
    assert_eq "1" "$(grep -c '^\[mcp_servers.fetch\]$' "$HOME/.codex/config.toml")"
    assert_file_not_exists "$HOME/projects/ainbox/.codex/config.toml"
}
