# AWS Integration Tests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add end-to-end integration tests that run provision.sh and destroy.sh against real AWS, validating the full lifecycle with tag-based isolation.

**Architecture:** Black-box tests run the actual scripts with test-specific env vars (`TAG=aoc-ci-test`, `AWS_REGION=us-west-2`). A custom sequential runner (not test-lib.sh's `run_tests()`) preserves state across tests. CI runs nightly + on-demand via OIDC auth; an hourly sweeper cleans orphaned resources.

**Tech Stack:** Bash, AWS CLI, GitHub Actions (OIDC), test-lib.sh assertions

**Spec:** `docs/superpowers/specs/2026-03-25-aws-integration-tests-design.md`

---

### Task 1: Make TAG overridable in deploy scripts

**Files:**
- Modify: `scripts/deploy/provision.sh:26`
- Modify: `scripts/deploy/destroy.sh:15`
- Modify: `scripts/deploy/build-ami.sh:27`

- [ ] **Step 1: Update provision.sh TAG**

In `scripts/deploy/provision.sh` line 26, change:
```bash
TAG="always-on-claude"
```
to:
```bash
TAG="${TAG:-always-on-claude}"
```

- [ ] **Step 2: Update destroy.sh TAG**

In `scripts/deploy/destroy.sh` line 15, change:
```bash
TAG="always-on-claude"
```
to:
```bash
TAG="${TAG:-always-on-claude}"
```

- [ ] **Step 3: Update build-ami.sh TAG**

In `scripts/deploy/build-ami.sh` line 27, change:
```bash
TAG="always-on-claude"
```
to:
```bash
TAG="${TAG:-always-on-claude}"
```

- [ ] **Step 4: Run existing tests to verify no regression**

Run: `bash tests/run.sh`
Expected: All 46 tests pass. TAG override is backwards-compatible — default value unchanged.

- [ ] **Step 5: Commit**

```bash
git add scripts/deploy/provision.sh scripts/deploy/destroy.sh scripts/deploy/build-ami.sh
git commit -m "Make TAG configurable via env var in deploy scripts"
```

---

### Task 2: Add non-interactive mode to destroy.sh

**Files:**
- Modify: `scripts/deploy/destroy.sh:82-87,120-133`

- [ ] **Step 1: Replace main confirmation prompt with TTY detection**

In `scripts/deploy/destroy.sh`, replace lines 82-87:
```bash
echo ""
read -rp "  Delete all of these? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "  Aborted."
    exit 0
fi
```
with:
```bash
echo ""
if [[ -t 0 ]]; then
    read -rp "  Delete all of these? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "  Aborted."
        exit 0
    fi
else
    echo "  (non-interactive mode — proceeding automatically)"
fi
```

- [ ] **Step 2: Replace key pair deletion prompt with TTY detection**

In `scripts/deploy/destroy.sh`, replace lines 120-133:
```bash
if [[ "$KEY_EXISTS" == "yes" ]]; then
    info "Delete SSH key pair?"

    read -rp "  Delete key pair '$KEY_NAME'? [y/N] " confirm_key
    if [[ "$confirm_key" == "y" || "$confirm_key" == "Y" ]]; then
        aws ec2 delete-key-pair \
            --region "$AWS_REGION" \
            --key-name "$KEY_NAME"
        rm -f "$KEY_FILE"
        ok "Key pair deleted"
    else
        echo "  Kept key pair '$KEY_NAME'"
    fi
fi
```
with:
```bash
if [[ "$KEY_EXISTS" == "yes" ]]; then
    info "Delete SSH key pair?"

    if [[ -t 0 ]]; then
        read -rp "  Delete key pair '$KEY_NAME'? [y/N] " confirm_key
        if [[ "$confirm_key" != "y" && "$confirm_key" != "Y" ]]; then
            echo "  Kept key pair '$KEY_NAME'"
            # skip deletion, continue to done
            KEY_EXISTS="kept"
        fi
    fi

    if [[ "$KEY_EXISTS" == "yes" ]]; then
        aws ec2 delete-key-pair \
            --region "$AWS_REGION" \
            --key-name "$KEY_NAME"
        rm -f "$KEY_FILE"
        ok "Key pair deleted"
    fi
fi
```

- [ ] **Step 3: Run existing tests to verify no regression**

Run: `bash tests/run.sh`
Expected: All 46 tests pass.

- [ ] **Step 4: Commit**

```bash
git add scripts/deploy/destroy.sh
git commit -m "Add non-interactive mode to destroy.sh for CI"
```

---

### Task 3: Add SKIP_SSH_WAIT to provision.sh

**Files:**
- Modify: `scripts/deploy/provision.sh:270-321`

- [ ] **Step 1: Add SKIP_SSH_WAIT guard after public IP retrieval**

In `scripts/deploy/provision.sh`, after line 268 (`ok "Running: $PUBLIC_IP"`), add:
```bash
if [[ "${SKIP_SSH_WAIT:-0}" == "1" ]]; then
    echo ""
    echo "============================================"
    echo "  Provisioning complete! (SSH wait skipped)"
    echo "============================================"
    echo ""
    echo "  Instance:  $INSTANCE_ID"
    echo "  Public IP: $PUBLIC_IP"
    echo "  SSH key:   $KEY_FILE"
    echo ""
    echo "  Connect:"
    echo "    ssh -i $KEY_FILE ${SSH_USER}@$PUBLIC_IP"
    echo ""
    exit 0
fi
```

This exits before the SSH readiness loop (line 270), cloud-init wait (line 290), container readiness loop (line 295), and `.env.workspace` write (line 308). The full output section at the end of the file (lines 323-342) is also skipped — replaced by the abbreviated output above.

- [ ] **Step 2: Run existing tests to verify no regression**

Run: `bash tests/run.sh`
Expected: All 46 tests pass. SKIP_SSH_WAIT defaults to unset, so normal flow is unchanged.

- [ ] **Step 3: Commit**

```bash
git add scripts/deploy/provision.sh
git commit -m "Add SKIP_SSH_WAIT flag to provision.sh for CI testing"
```

---

### Task 4: Tag resources at creation time in provision.sh

**Files:**
- Modify: `scripts/deploy/provision.sh:135-143,158-175`

- [ ] **Step 1: Add --tag-specifications to create-key-pair**

In `scripts/deploy/provision.sh`, replace lines 135-140:
```bash
    aws ec2 create-key-pair \
        --key-name "$KEY_NAME" \
        --key-type ed25519 \
        --region "$AWS_REGION" \
        --query 'KeyMaterial' \
        --output text > "$KEY_FILE"
```
with:
```bash
    aws ec2 create-key-pair \
        --key-name "$KEY_NAME" \
        --key-type ed25519 \
        --region "$AWS_REGION" \
        --tag-specifications "ResourceType=key-pair,Tags=[{Key=Project,Value=$TAG}]" \
        --query 'KeyMaterial' \
        --output text > "$KEY_FILE"
```

- [ ] **Step 2: Add --tag-specifications to create-security-group and remove separate create-tags call**

In `scripts/deploy/provision.sh`, replace lines 158-175:
```bash
    SG_ID=$(aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name "$SG_NAME" \
        --description "SSH access for always-on Claude Code" \
        --query 'GroupId' \
        --output text)

    aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$SG_ID" \
        --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null

    aws ec2 create-tags \
        --region "$AWS_REGION" \
        --resources "$SG_ID" \
        --tags Key=Project,Value="$TAG" Key=Name,Value="$SG_NAME"

    ok "Created security group: $SG_ID"
```
with:
```bash
    SG_ID=$(aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name "$SG_NAME" \
        --description "SSH access for always-on Claude Code" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{Key=Project,Value=$TAG}]" \
        --query 'GroupId' \
        --output text)

    aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$SG_ID" \
        --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null

    ok "Created security group: $SG_ID"
```

- [ ] **Step 3: Run existing tests to verify no regression**

Run: `bash tests/run.sh`
Expected: All 46 tests pass.

- [ ] **Step 4: Commit**

```bash
git add scripts/deploy/provision.sh
git commit -m "Tag key pairs and security groups at creation time"
```

---

### Task 5: Write the test file

**Files:**
- Create: `tests/aws-lifecycle.sh`

Note: This file is intentionally NOT named `test-*.sh` to avoid auto-discovery by `tests/run.sh`, which sources files and calls `run_tests()`. The AWS integration test has its own runner and must be invoked directly.

- [ ] **Step 1: Create the test file with guard, env setup, runner, and all 7 tests**

Create `tests/aws-lifecycle.sh`:

```bash
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
    local orphan_sg
    orphan_sg=$(aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name "${SG_NAME}-orphan" \
        --description "Orphaned test SG" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$TAG}]" \
        --query 'GroupId' \
        --output text)

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
```

- [ ] **Step 2: Verify the guard works (skips without AWS_INTEGRATION)**

Run: `bash tests/aws-lifecycle.sh`
Expected: `SKIP: AWS integration tests (set AWS_INTEGRATION=1 to run)`

- [ ] **Step 3: Verify run.sh is unaffected**

Run: `bash tests/run.sh`
Expected: All 46 existing tests pass. `aws-lifecycle.sh` is NOT discovered because it does not match the `test-*.sh` glob.

- [ ] **Step 4: Commit**

```bash
git add tests/aws-lifecycle.sh
git commit -m "Add AWS integration test file for provision/destroy lifecycle"
```

---

### Task 6: Create the CI workflow

**Files:**
- Create: `.github/workflows/aws-integration.yml`

- [ ] **Step 1: Create the workflow file**

Create `.github/workflows/aws-integration.yml`:

```yaml
name: AWS integration tests

on:
  schedule:
    - cron: '0 6 * * *'  # Daily at 06:00 UTC
  workflow_dispatch:       # Manual trigger

concurrency:
  group: aws-integration
  cancel-in-progress: false

permissions:
  id-token: write
  contents: read

jobs:
  aws-lifecycle:
    name: Provision + destroy lifecycle
    runs-on: ubuntu-latest
    environment: aws-integration-test
    timeout-minutes: 10
    env:
      AWS_INTEGRATION: '1'
      TAG: aoc-ci-test
      AWS_REGION: us-west-2
      INSTANCE_TYPE: t4g.micro
      SKIP_SSH_WAIT: '1'
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_CI_ROLE_ARN }}
          aws-region: us-west-2

      - name: Generate unique resource names
        run: |
          echo "INSTANCE_NAME=aoc-ci-${{ github.run_id }}" >> "$GITHUB_ENV"
          echo "KEY_NAME=aoc-ci-key-${{ github.run_id }}" >> "$GITHUB_ENV"
          echo "SG_NAME=aoc-ci-sg-${{ github.run_id }}" >> "$GITHUB_ENV"

      - name: Run lifecycle tests
        run: bash tests/aws-lifecycle.sh

      - name: Cleanup (always)
        if: always()
        env:
          TAG: aoc-ci-test
          AWS_REGION: us-west-2
        run: |
          # Non-interactive: stdin is not a TTY in CI, so destroy.sh auto-confirms
          bash scripts/deploy/destroy.sh || true
```

- [ ] **Step 2: Validate workflow syntax**

Run: `cd /home/dev/projects/always-on-claude && python3 -c "import yaml; yaml.safe_load(open('.github/workflows/aws-integration.yml'))" && echo "Valid YAML"`
Expected: `Valid YAML`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/aws-integration.yml
git commit -m "Add AWS integration test workflow (nightly + manual)"
```

---

### Task 7: Create the cleanup sweeper workflow

**Files:**
- Create: `.github/workflows/aws-cleanup-sweeper.yml`

- [ ] **Step 1: Create the sweeper workflow file**

Create `.github/workflows/aws-cleanup-sweeper.yml`:

```yaml
name: AWS resource sweeper

on:
  schedule:
    - cron: '0 * * * *'  # Every hour
  workflow_dispatch:       # Manual trigger

permissions:
  id-token: write
  contents: read

jobs:
  sweep:
    name: Clean orphaned test resources
    runs-on: ubuntu-latest
    environment: aws-integration-test
    timeout-minutes: 5
    steps:
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_CI_ROLE_ARN }}
          aws-region: us-west-2

      - name: Sweep old resources
        run: |
          # Note: uses GNU date (-d flag) — only runs on ubuntu-latest, not macOS
          CUTOFF=$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%S)

          echo "Sweeping resources older than $CUTOFF"

          # Terminate instances tagged aoc-ci-test launched > 30 minutes ago
          OLD_INSTANCES=$(aws ec2 describe-instances \
            --region us-west-2 \
            --filters \
              "Name=tag:Project,Values=aoc-ci-test" \
              "Name=instance-state-name,Values=running,stopped,pending" \
            --query "Reservations[].Instances[?LaunchTime<=\`${CUTOFF}\`].InstanceId" \
            --output text)

          if [[ -n "$OLD_INSTANCES" && "$OLD_INSTANCES" != "None" ]]; then
            echo "Terminating stale instances: $OLD_INSTANCES"
            aws ec2 terminate-instances --region us-west-2 --instance-ids $OLD_INSTANCES
            aws ec2 wait instance-terminated --region us-west-2 --instance-ids $OLD_INSTANCES
          else
            echo "No stale instances found"
          fi

          # Delete orphaned security groups (tagged aoc-ci-test)
          SG_IDS=$(aws ec2 describe-security-groups \
            --region us-west-2 \
            --filters "Name=tag:Project,Values=aoc-ci-test" \
            --query 'SecurityGroups[].GroupId' \
            --output text)

          if [[ -n "$SG_IDS" && "$SG_IDS" != "None" ]]; then
            for sg in $SG_IDS; do
              aws ec2 delete-security-group --region us-west-2 --group-id "$sg" 2>/dev/null \
                && echo "Deleted SG $sg" || echo "SG $sg still in use, skipping"
            done
          else
            echo "No orphaned security groups found"
          fi

          # Delete orphaned key pairs — aoc-ci- prefix AND created > 30 min ago
          aws ec2 describe-key-pairs --region us-west-2 \
            --query "KeyPairs[?starts_with(KeyName, \`aoc-ci-\`) && CreateTime<=\`${CUTOFF}\`].KeyName" \
            --output text | tr '\t' '\n' | while read -r kp; do
            [[ -n "$kp" ]] && aws ec2 delete-key-pair --region us-west-2 --key-name "$kp" \
              && echo "Deleted key pair $kp"
          done

          echo "Sweep complete"
```

- [ ] **Step 2: Validate workflow syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/aws-cleanup-sweeper.yml'))" && echo "Valid YAML"`
Expected: `Valid YAML`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/aws-cleanup-sweeper.yml
git commit -m "Add hourly AWS resource sweeper for test cleanup"
```

---

### Task 8: Verify full test suite still passes

**Files:** None (verification only)

- [ ] **Step 1: Run all existing tests**

Run: `bash tests/run.sh`
Expected: All 46 existing tests pass. AWS integration test file prints SKIP and exits 0.

- [ ] **Step 2: Verify ShellCheck passes on modified files**

Run: `shellcheck -S warning scripts/deploy/provision.sh scripts/deploy/destroy.sh scripts/deploy/build-ami.sh tests/aws-lifecycle.sh`
Expected: No errors (warnings acceptable, matching existing project tolerance).

- [ ] **Step 3: Commit any ShellCheck fixes if needed**

```bash
git add -A && git commit -m "Fix ShellCheck warnings in deploy scripts and test file"
```
Only run this if step 2 found issues that needed fixing.

---

### Post-Implementation: Manual OIDC Setup (not automated)

These steps must be done manually by the repo owner in AWS Console + GitHub Settings. They are documented here for reference — not part of the automated implementation.

1. **AWS Console → IAM → Identity providers:** Create OIDC provider for `https://token.actions.githubusercontent.com` with audience `sts.amazonaws.com`
2. **AWS Console → IAM → Roles:** Create `aoc-ci-test-role` with the trust policy and permissions policy from the spec
3. **GitHub → Repo Settings → Variables:** Add `AWS_CI_ROLE_ARN` with the role ARN
4. **GitHub → Repo Settings → Environments:** Create `aws-integration-test` environment
5. **Test manually:** Trigger the workflow via `gh workflow run aws-integration.yml` and monitor
