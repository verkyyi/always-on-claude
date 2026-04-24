#!/bin/bash
# Tests for scripts/deploy/load-config.sh

setup() {
    # Create a fake repo structure so load-config.sh can find repo root
    mkdir -p "$HOME/dev-env/scripts/deploy"
    # Copy the real load-config.sh
    cp "$REPO_ROOT/scripts/deploy/load-config.sh" "$HOME/dev-env/scripts/deploy/"

    # Mock aws CLI (load-config.sh calls `aws configure get region`)
    mock_binary aws ""
}

_source_config() {
    # Source load-config.sh from the fake repo, capturing env vars
    (
        cd "$HOME/dev-env"
        SCRIPT_DIR="$HOME/dev-env/scripts/deploy"
        # shellcheck disable=SC1091
        source "$HOME/dev-env/scripts/deploy/load-config.sh"
        # Print requested var
        echo "${!1}"
    )
}

test_defaults_applied() {
    local result
    result=$(_source_config INSTANCE_TYPE)
    assert_eq "t4g.small" "$result"
}

test_defaults_container_name() {
    local result
    result=$(_source_config CONTAINER_NAME)
    assert_eq "claude-dev" "$result"
}

test_defaults_docker_image() {
    local result
    result=$(_source_config DOCKER_IMAGE)
    assert_eq "ghcr.io/verkyyi/always-on-claude:latest" "$result"
}

test_defaults_dev_env_path() {
    local result
    result=$(_source_config DEV_ENV)
    assert_eq "$HOME/dev-env" "$result"
}

test_defaults_code_agent() {
    local result
    result=$(_source_config DEFAULT_CODE_AGENT)
    assert_eq "claude" "$result"
}

test_env_file_overrides_defaults() {
    cat > "$HOME/dev-env/.env" <<'EOF'
INSTANCE_TYPE=t3.large
CONTAINER_NAME=my-claude
EOF
    local result
    result=$(_source_config INSTANCE_TYPE)
    assert_eq "t3.large" "$result"

    result=$(_source_config CONTAINER_NAME)
    assert_eq "my-claude" "$result"
}

test_env_var_overrides_env_file() {
    cat > "$HOME/dev-env/.env" <<'EOF'
INSTANCE_TYPE=t3.large
EOF
    local result
    result=$(INSTANCE_TYPE=t3.xlarge _source_config INSTANCE_TYPE)
    assert_eq "t3.xlarge" "$result"
}

test_env_var_overrides_defaults() {
    local result
    result=$(VOLUME_SIZE=50 _source_config VOLUME_SIZE)
    assert_eq "50" "$result"
}

test_env_var_overrides_code_agent() {
    local result
    result=$(DEFAULT_CODE_AGENT=codex _source_config DEFAULT_CODE_AGENT)
    assert_eq "codex" "$result"
}

test_legacy_tag_compat() {
    local result
    result=$(_source_config TAG)
    assert_eq "always-on-claude" "$result"
}

test_legacy_image_compat() {
    local result
    result=$(_source_config IMAGE)
    assert_eq "ghcr.io/verkyyi/always-on-claude:latest" "$result"
}

test_env_file_with_custom_tag() {
    cat > "$HOME/dev-env/.env" <<'EOF'
PROJECT_TAG=my-project
EOF
    local result
    result=$(_source_config TAG)
    assert_eq "my-project" "$result"
}

test_no_env_file_uses_defaults() {
    # Ensure no .env exists
    rm -f "$HOME/dev-env/.env"
    local result
    result=$(_source_config SSH_USER)
    assert_eq "dev" "$result"
}

test_three_tier_precedence() {
    # .env sets one value, env var overrides a different one, default fills the third
    cat > "$HOME/dev-env/.env" <<'EOF'
INSTANCE_TYPE=from-env-file
VOLUME_SIZE=30
EOF
    local instance_type volume_size key_name
    instance_type=$(INSTANCE_TYPE=from-shell _source_config INSTANCE_TYPE)
    volume_size=$(_source_config VOLUME_SIZE)
    key_name=$(_source_config KEY_NAME)

    assert_eq "from-shell" "$instance_type" "env var should override .env"
    assert_eq "30" "$volume_size" ".env should override default"
    assert_eq "claude-dev-key" "$key_name" "default should apply when no override"
}
