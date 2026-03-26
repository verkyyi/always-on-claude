#!/bin/bash
# Tests for scripts/runtime/backup.sh

BACKUP_SCRIPT="$REPO_ROOT/scripts/runtime/backup.sh"

setup() {
    # Mock aws CLI
    local log_file="$TEST_DIR/bin/aws.log"
    cat > "$TEST_DIR/bin/aws" <<MOCK
#!/bin/bash
echo "\$0 \$*" >> "$log_file"
case "\$1" in
    sts)
        echo '{"Account":"123456789012"}'
        ;;
    ec2)
        case "\$2" in
            describe-instances)
                echo "vol-abc123"
                ;;
            create-snapshot)
                echo "snap-new123"
                ;;
            describe-snapshots)
                printf "snap-001\tsnap-002\tsnap-003"
                ;;
            delete-snapshot)
                echo "deleted"
                ;;
        esac
        ;;
esac
MOCK
    chmod +x "$TEST_DIR/bin/aws"

    # Mock curl for instance metadata (fail — will fall back to .env.workspace)
    cat > "$TEST_DIR/bin/curl" <<'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$TEST_DIR/bin/curl"

    # Create .env.workspace with instance ID
    mkdir -p "$HOME/dev-env"
    echo 'INSTANCE_ID=i-test123' > "$HOME/dev-env/.env.workspace"

    # Point BASH_SOURCE resolution to the right place
    mkdir -p "$HOME/dev-env/scripts/runtime"
    cp "$BACKUP_SCRIPT" "$HOME/dev-env/scripts/runtime/backup.sh"
}

test_arg_parsing_no_prune() {
    local output
    output=$(bash "$HOME/dev-env/scripts/runtime/backup.sh" --no-prune 2>&1)
    # Should create a snapshot but NOT prune
    local log
    log=$(cat "$TEST_DIR/bin/aws.log")
    assert_contains "$log" "create-snapshot"
    if [[ "$log" == *"describe-snapshots"* ]]; then
        _fail "should not call describe-snapshots with --no-prune"
    fi
}

test_arg_parsing_prune_only() {
    local output
    output=$(bash "$HOME/dev-env/scripts/runtime/backup.sh" --prune-only 2>&1)
    local log
    log=$(cat "$TEST_DIR/bin/aws.log")
    # Should NOT create snapshot
    if [[ "$log" == *"create-snapshot"* ]]; then
        _fail "should not create snapshot with --prune-only"
    fi
    # Should call describe-snapshots for pruning
    assert_contains "$log" "describe-snapshots"
}

test_arg_parsing_unknown_arg_fails() {
    local exit_code=0
    bash "$HOME/dev-env/scripts/runtime/backup.sh" --bogus 2>/dev/null || exit_code=$?
    assert_neq "0" "$exit_code" "should fail on unknown arg"
}

test_keep_validation_rejects_non_number() {
    local exit_code=0
    bash "$HOME/dev-env/scripts/runtime/backup.sh" --keep abc 2>/dev/null || exit_code=$?
    assert_neq "0" "$exit_code" "should reject non-numeric --keep"
}

test_keep_validation_rejects_zero() {
    local exit_code=0
    bash "$HOME/dev-env/scripts/runtime/backup.sh" --keep 0 2>/dev/null || exit_code=$?
    assert_neq "0" "$exit_code" "should reject --keep 0"
}

test_fails_without_aws_cli() {
    rm -f "$TEST_DIR/bin/aws"
    local exit_code=0
    bash "$HOME/dev-env/scripts/runtime/backup.sh" 2>/dev/null || exit_code=$?
    assert_neq "0" "$exit_code" "should fail without aws CLI"
}

test_fails_with_bad_credentials() {
    cat > "$TEST_DIR/bin/aws" <<MOCK
#!/bin/bash
if [[ "\$1" == "sts" ]]; then
    exit 1
fi
MOCK
    chmod +x "$TEST_DIR/bin/aws"
    local exit_code=0
    bash "$HOME/dev-env/scripts/runtime/backup.sh" 2>/dev/null || exit_code=$?
    assert_neq "0" "$exit_code" "should fail with bad credentials"
}

test_discovers_instance_from_env_workspace() {
    local output
    output=$(bash "$HOME/dev-env/scripts/runtime/backup.sh" --no-prune 2>&1)
    assert_contains "$output" "i-test123"
}

test_creates_snapshot_with_tags() {
    bash "$HOME/dev-env/scripts/runtime/backup.sh" --no-prune 2>&1 >/dev/null
    local log
    log=$(cat "$TEST_DIR/bin/aws.log")
    assert_contains "$log" "create-snapshot"
    assert_contains "$log" "always-on-claude"
}

test_owner_ids_self_on_describe_snapshots() {
    bash "$HOME/dev-env/scripts/runtime/backup.sh" --prune-only 2>&1 >/dev/null
    local log
    log=$(cat "$TEST_DIR/bin/aws.log")
    assert_contains "$log" "--owner-ids self"
}
