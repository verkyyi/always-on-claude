#!/bin/bash
# Tests for scripts/deploy/verify-staging.sh

setup() {
    mkdir -p "$HOME/repo/scripts/deploy"
    cp "$REPO_ROOT/scripts/deploy/verify-staging.sh" "$HOME/repo/scripts/deploy/"
    cp "$REPO_ROOT/scripts/deploy/load-config.sh" "$HOME/repo/scripts/deploy/"
}

_eval_verify() {
    local snippet="$1"
    (
        cd "$HOME/repo"
        # shellcheck disable=SC1091
        source "$HOME/repo/scripts/deploy/verify-staging.sh"
        eval "$snippet"
    )
}

test_defaults_to_remote_linux_paths() {
    local dev_env projects_dir
    dev_env=$(_eval_verify 'echo "$DEV_ENV"; cleanup_all >/dev/null 2>&1 || true')
    projects_dir=$(_eval_verify 'echo "$PROJECTS_DIR"; cleanup_all >/dev/null 2>&1 || true')

    assert_eq "/home/dev/dev-env" "$dev_env"
    assert_eq "/home/dev/projects" "$projects_dir"
}

test_defaults_to_staging_safe_instance_size() {
    local instance_type volume_size
    instance_type=$(_eval_verify 'echo "$INSTANCE_TYPE"; cleanup_all >/dev/null 2>&1 || true')
    volume_size=$(_eval_verify 'echo "$VOLUME_SIZE"; cleanup_all >/dev/null 2>&1 || true')

    assert_eq "t3.medium" "$instance_type"
    assert_eq "20" "$volume_size"
}

test_defaults_to_codex_agent() {
    local agent
    agent=$(_eval_verify 'echo "$DEFAULT_CODE_AGENT"; cleanup_all >/dev/null 2>&1 || true')
    assert_eq "codex" "$agent"
}

test_find_ami_returns_success_when_ami_exists() {
    local result
    result=$(_eval_verify '
        ARCH=x86_64
        STAGING_AMI_SOURCE=stock
        find_stock_ubuntu_ami() { echo "ami-test123"; }
        find_ami
        printf "%s|%s|%s\n" "$?" "$AMI_ID" "$AMI_SOURCE_USED"
        cleanup_all >/dev/null 2>&1 || true
    ')

    assert_eq "0|ami-test123|stock" "$result"
}

test_resolve_instance_arch() {
    local arm64 x86_64
    arm64=$(_eval_verify 'resolve_instance_arch t4g.medium; cleanup_all >/dev/null 2>&1 || true')
    x86_64=$(_eval_verify 'resolve_instance_arch t3.medium; cleanup_all >/dev/null 2>&1 || true')

    assert_eq "arm64" "$arm64"
    assert_eq "x86_64" "$x86_64"
}

test_cleanup_keeps_key_when_failure_is_preserved() {
    local result
    result=$(_eval_verify '
        tmp_dir="$TMP_DIR"
        printf "test" > "$KEY_FILE"
        INSTANCE_ID="i-123456"
        status="failed"
        KEEP_ON_FAILURE=1
        cleanup_all >/dev/null 2>&1 || true
        if [[ -f "$KEY_FILE" ]]; then
            echo "kept"
        else
            echo "missing"
        fi
        rm -rf "$tmp_dir"
    ')

    assert_eq "kept" "$result"
}

test_cleanup_removes_temp_dir_when_not_kept() {
    local result
    result=$(_eval_verify '
        tmp_dir="$TMP_DIR"
        cleanup_all >/dev/null 2>&1 || true
        if [[ -e "$tmp_dir" ]]; then
            echo "present"
        else
            echo "removed"
        fi
    ')

    assert_eq "removed" "$result"
}
