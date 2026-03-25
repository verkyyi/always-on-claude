#!/bin/bash
# aws-lifecycle.sh — Integration tests for provision.sh + destroy.sh
# against real AWS. Requires AWS credentials and AWS_INTEGRATION=1.
#
# Named aws-lifecycle.sh (not test-*.sh) to avoid auto-discovery by
# tests/run.sh, which sources files — this file has its own runner.
#
# Usage:
#   AWS_INTEGRATION=1 TAG=aoc-ci-test AWS_REGION=us-west-2 bash tests/aws-lifecycle.sh

set -euo pipefail

# --- Guard: skip without explicit opt-in --------------------------------------

if [[ -z "${AWS_INTEGRATION:-}" ]]; then
    echo "SKIP: AWS integration tests (set AWS_INTEGRATION=1 to run)"
    exit 0
fi

# --- Preflight ----------------------------------------------------------------

command -v aws &>/dev/null || { echo "ERROR: aws CLI is required"; exit 1; }
command -v jq &>/dev/null || { echo "ERROR: jq is required"; exit 1; }

# --- Load assertions from test-lib.sh (not the runner) -----------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Environment --------------------------------------------------------------

export TAG="${TAG:-aoc-ci-test}"
export AWS_REGION="${AWS_REGION:-us-west-2}"

_RUN_ID="${GITHUB_RUN_ID:-$(date +%s)}"
export INSTANCE_NAME="${INSTANCE_NAME:-aoc-ci-${_RUN_ID}}"
export KEY_NAME="${KEY_NAME:-aoc-ci-key-${_RUN_ID}}"
export SG_NAME="${SG_NAME:-aoc-ci-sg-${_RUN_ID}}"
export INSTANCE_TYPE="${INSTANCE_TYPE:-t4g.micro}"
export SKIP_SSH_WAIT=1

# --- Helpers ------------------------------------------------------------------

_PASS=0
_FAIL=0

run_test() {
    local name="$1"
    echo -n "  "
    if "$name"; then
        echo "${_GREEN}PASS${_RESET} $name"
        ((_PASS++)) || true
    else
        echo "${_RED}FAIL${_RESET} $name"
        ((_FAIL++)) || true
    fi
}

# Failsafe: always attempt cleanup on exit
cleanup() {
    echo ""
    echo "=== Cleanup (failsafe) ==="
    TAG="$TAG" AWS_REGION="$AWS_REGION" KEY_NAME="$KEY_NAME" \
        bash "$REPO_ROOT/scripts/deploy/destroy.sh" 2>&1 || true
}
trap cleanup EXIT

# --- AWS helpers --------------------------------------------------------------

describe_test_instances() {
    aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters \
            "Name=tag:Project,Values=$TAG" \
            "Name=tag:Name,Values=$INSTANCE_NAME" \
            "Name=instance-state-name,Values=running,pending" \
        --query 'Reservations[].Instances[]' \
        --output json 2>/dev/null
}

count_test_instances() {
    describe_test_instances | jq 'length'
}

# --- Tests (run sequentially) ------------------------------------------------

test_01_provision_creates_instance() {
    local output
    output=$(bash "$REPO_ROOT/scripts/deploy/provision.sh" 2>&1)

    # Instance exists with correct tags
    local count
    count=$(count_test_instances)
    assert_eq "1" "$count" "expected 1 instance, got $count"

    # Instance type matches
    local actual_type
    actual_type=$(describe_test_instances | jq -r '.[0].InstanceType')
    assert_eq "$INSTANCE_TYPE" "$actual_type" "expected type $INSTANCE_TYPE, got $actual_type"
}

test_02_provision_creates_security_group() {
    # SG exists with correct tag
    local sg_json
    sg_json=$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --filters "Name=group-name,Values=$SG_NAME" \
        --query 'SecurityGroups[0]' \
        --output json 2>/dev/null)

    local sg_id
    sg_id=$(echo "$sg_json" | jq -r '.GroupId')
    assert_neq "null" "$sg_id" "security group $SG_NAME not found"

    # Has Project tag
    local project_tag
    project_tag=$(echo "$sg_json" | jq -r '.Tags[] | select(.Key=="Project") | .Value')
    assert_eq "$TAG" "$project_tag" "SG missing Project=$TAG tag"

    # Has SSH ingress rule
    local ssh_port
    ssh_port=$(echo "$sg_json" | jq -r '.IpPermissions[] | select(.FromPort==22) | .FromPort')
    assert_eq "22" "$ssh_port" "SG missing SSH ingress rule"
}

test_03_provision_creates_key_pair() {
    # Key pair exists in AWS
    aws ec2 describe-key-pairs \
        --key-names "$KEY_NAME" \
        --region "$AWS_REGION" \
        --output text >/dev/null 2>&1 \
        || _fail "key pair $KEY_NAME not found in AWS"

    # Key pair has Project tag
    local project_tag
    project_tag=$(aws ec2 describe-key-pairs \
        --key-names "$KEY_NAME" \
        --region "$AWS_REGION" \
        --query 'KeyPairs[0].Tags[?Key==`Project`].Value' \
        --output text 2>/dev/null)
    assert_eq "$TAG" "$project_tag" "key pair missing Project=$TAG tag"

    # Local .pem file exists
    assert_file_exists "$HOME/.ssh/${KEY_NAME}.pem"
}

test_04_provision_is_idempotent() {
    local output
    output=$(bash "$REPO_ROOT/scripts/deploy/provision.sh" 2>&1)

    # Outputs "already running"
    assert_contains "$output" "already running"

    # Still exactly one instance
    local count
    count=$(count_test_instances)
    assert_eq "1" "$count" "expected 1 instance after re-run, got $count"
}

test_05_destroy_terminates_resources() {
    bash "$REPO_ROOT/scripts/deploy/destroy.sh" 2>&1

    # No running/pending instances
    local count
    count=$(count_test_instances)
    assert_eq "0" "$count" "expected 0 instances after destroy, got $count"

    # SG deleted
    local sg_count
    sg_count=$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --filters "Name=group-name,Values=$SG_NAME" \
        --query 'SecurityGroups | length(@)' \
        --output text 2>/dev/null)
    assert_eq "0" "$sg_count" "security group $SG_NAME still exists"

    # Key pair deleted
    if aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$AWS_REGION" &>/dev/null 2>&1; then
        _fail "key pair $KEY_NAME still exists after destroy"
    fi
}

test_06_destroy_is_idempotent() {
    local output
    output=$(bash "$REPO_ROOT/scripts/deploy/destroy.sh" 2>&1)

    assert_contains "$output" "Nothing to delete"
}

# test_07 must run after test_05 has deleted the key pair.
# destroy.sh looks up key pairs by KEY_NAME — if one existed,
# it would hit the key pair deletion prompt in non-TTY mode.
test_07_partial_provision_cleanup() {
    # Create an orphaned SG manually (simulating mid-provision failure)
    aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name "${SG_NAME}-orphan" \
        --description "Orphaned test SG" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$TAG}]" \
        --query 'GroupId' \
        --output text >/dev/null

    # destroy.sh should find and clean it up via Project tag
    bash "$REPO_ROOT/scripts/deploy/destroy.sh" 2>&1

    # Verify orphaned SG is gone
    local sg_count
    sg_count=$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --filters "Name=group-name,Values=${SG_NAME}-orphan" \
        --query 'SecurityGroups | length(@)' \
        --output text 2>/dev/null)
    assert_eq "0" "$sg_count" "orphaned SG ${SG_NAME}-orphan still exists"
}

# --- Run all tests sequentially -----------------------------------------------

echo ""
echo "=== AWS Integration Tests ==="
echo "  TAG=$TAG  REGION=$AWS_REGION  RUN_ID=$_RUN_ID"
echo ""

run_test test_01_provision_creates_instance
run_test test_02_provision_creates_security_group
run_test test_03_provision_creates_key_pair
run_test test_04_provision_is_idempotent
run_test test_05_destroy_terminates_resources
run_test test_06_destroy_is_idempotent
run_test test_07_partial_provision_cleanup

# Disable the cleanup trap — tests already destroyed everything
trap - EXIT

echo ""
total=$((_PASS + _FAIL))
if [[ $_FAIL -eq 0 ]]; then
    echo "${_GREEN}All $total AWS integration tests passed${_RESET}"
else
    echo "${_RED}$_FAIL/$total AWS integration tests failed${_RESET}"
    exit 1
fi
