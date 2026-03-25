# AWS Integration Tests — Design Spec

**Date:** 2026-03-25
**Status:** Draft
**Scope:** provision.sh + destroy.sh lifecycle testing against real AWS

## Goal

Test the AWS orchestration logic in `provision.sh` and `destroy.sh` against real AWS APIs to catch permission drift, API changes, and logic bugs that unit-level mocking cannot detect.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Test target | provision.sh + destroy.sh (core lifecycle) | Most critical user-facing path; extend later |
| CI trigger | Nightly schedule + manual dispatch | Avoids cost on every PR; nightly catches drift |
| Cleanup safety net | Inline trap + hourly sweeper workflow | Belt-and-suspenders; sweeper catches CI runner crashes |
| AWS auth in CI | OIDC federation (no long-lived keys) | AWS-recommended; no secrets to rotate |
| Test region | us-west-2 | Tag + region isolation from prod (us-east-1) |
| Test approach | End-to-end black-box (Approach A) | Scripts already support non-interactive mode; no refactoring needed |

## Isolation Strategy

All test resources are isolated from production by **two mechanisms**:

1. **Tag:** `Project=aoc-ci-test` (prod uses `Project=always-on-claude`)
2. **Region:** `us-west-2` (prod uses user's configured region, typically `us-east-1`)

Resource names include the CI run ID to avoid collisions between concurrent runs:
- Instance: `aoc-ci-<run_id>`
- Key pair: `aoc-ci-key-<run_id>`
- Security group: `aoc-ci-sg-<run_id>`

The IAM role used by CI is scoped with a condition `aws:RequestTag/Project = aoc-ci-test` on write operations, making it impossible for tests to touch prod resources.

## Script Modifications

### destroy.sh — Non-interactive mode

`provision.sh` already detects piped input (`[[ -t 0 ]]`) and skips confirmation prompts. `destroy.sh` has two `read -rp` prompts that block in CI.

**Change:** Add the same TTY detection pattern:
- Main confirmation prompt: auto-proceed when stdin is not a TTY
- Key pair deletion prompt: auto-delete when stdin is not a TTY

No other scripts need changes.

## Test File

### `tests/test-aws-lifecycle.sh`

Sources `test-lib.sh` for assertions and the test runner framework. Runs 6 tests sequentially (order matters — provision must complete before destroy verification).

#### Environment Setup

```bash
export TAG="aoc-ci-test"
export AWS_REGION="us-west-2"
export INSTANCE_NAME="aoc-ci-${GITHUB_RUN_ID:-$(date +%s)}"
export KEY_NAME="aoc-ci-key-${GITHUB_RUN_ID:-$(date +%s)}"
export SG_NAME="aoc-ci-sg-${GITHUB_RUN_ID:-$(date +%s)}"
export INSTANCE_TYPE="t4g.micro"  # smallest/cheapest for tests
```

A `trap` on EXIT always runs `destroy.sh` as a failsafe regardless of test outcome.

#### Tests

**test_provision_creates_instance**
- Runs `provision.sh` (piped mode, auto-confirms)
- Asserts: `aws ec2 describe-instances` finds exactly one instance with tags `Project=aoc-ci-test` and `Name=$INSTANCE_NAME` in state `running` or `pending`

**test_provision_creates_security_group**
- Asserts: SG named `$SG_NAME` exists with `Project=aoc-ci-test` tag
- Asserts: SG has an ingress rule for TCP port 22

**test_provision_creates_key_pair**
- Asserts: `aws ec2 describe-key-pairs --key-names $KEY_NAME` succeeds
- Asserts: local `.pem` file exists at `$HOME/.ssh/$KEY_NAME.pem`

**test_provision_is_idempotent**
- Runs `provision.sh` a second time
- Asserts: exits 0, outputs "already running", does not create a second instance
- Asserts: `describe-instances` still returns exactly one instance

**test_destroy_terminates_resources**
- Runs `destroy.sh` (non-interactive, auto-confirms)
- Asserts: no instances with `Project=aoc-ci-test` in running/stopped/pending state
- Asserts: no SG named `$SG_NAME` exists

**test_destroy_is_idempotent**
- Runs `destroy.sh` a second time
- Asserts: exits 0, outputs "Nothing to delete"

#### What Tests Skip

- **SSH into the instance** — Would require the private key in CI and waiting for full boot + Docker pull (~60s+). The AWS orchestration is the test target, not the boot sequence.
- **User data / install.sh execution** — Runs inside the instance, already covered by smoke tests.
- **Container readiness polling** — The `for` loop waiting for `docker ps` is skipped since we don't SSH in.

To skip the SSH-dependent sections, provision.sh is run and allowed to timeout/fail on the SSH wait step. The test only asserts on AWS resource state, not SSH reachability. Alternatively, provision.sh could be modified to accept a `SKIP_SSH_WAIT=1` flag that exits after instance launch — this is cleaner and avoids a slow timeout.

**Recommendation:** Add `SKIP_SSH_WAIT=1` env var to provision.sh that exits after the instance is confirmed running, skipping SSH and container wait loops.

## CI Workflows

### `.github/workflows/aws-integration.yml`

```yaml
name: AWS integration tests

on:
  schedule:
    - cron: '0 6 * * *'  # Daily at 06:00 UTC
  workflow_dispatch:       # Manual trigger

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
      TAG: aoc-ci-test
      AWS_REGION: us-west-2
      INSTANCE_TYPE: t4g.micro
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_CI_ROLE_ARN }}
          aws-region: us-west-2

      - name: Run lifecycle tests
        run: bash tests/test-aws-lifecycle.sh

      - name: Cleanup (always)
        if: always()
        run: |
          export TAG=aoc-ci-test AWS_REGION=us-west-2
          echo "y" | bash scripts/deploy/destroy.sh || true
```

### `.github/workflows/aws-cleanup-sweeper.yml`

```yaml
name: AWS resource sweeper

on:
  schedule:
    - cron: '0 * * * *'  # Every hour

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
          # Terminate instances tagged aoc-ci-test running > 30 minutes
          OLD_INSTANCES=$(aws ec2 describe-instances \
            --region us-west-2 \
            --filters \
              "Name=tag:Project,Values=aoc-ci-test" \
              "Name=instance-state-name,Values=running,stopped,pending" \
            --query 'Reservations[].Instances[?LaunchTime<=`'"$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%S)"'`].InstanceId' \
            --output text)

          if [[ -n "$OLD_INSTANCES" && "$OLD_INSTANCES" != "None" ]]; then
            echo "Terminating stale instances: $OLD_INSTANCES"
            aws ec2 terminate-instances --region us-west-2 --instance-ids $OLD_INSTANCES
            aws ec2 wait instance-terminated --region us-west-2 --instance-ids $OLD_INSTANCES
          fi

          # Delete orphaned security groups
          SG_IDS=$(aws ec2 describe-security-groups \
            --region us-west-2 \
            --filters "Name=tag:Project,Values=aoc-ci-test" \
            --query 'SecurityGroups[].GroupId' \
            --output text)

          for sg in $SG_IDS; do
            aws ec2 delete-security-group --region us-west-2 --group-id "$sg" 2>/dev/null \
              && echo "Deleted SG $sg" || echo "SG $sg still in use, skipping"
          done

          # Delete orphaned key pairs (aoc-ci- prefix)
          aws ec2 describe-key-pairs --region us-west-2 \
            --query 'KeyPairs[?starts_with(KeyName, `aoc-ci-`)].KeyName' \
            --output text | tr '\t' '\n' | while read -r kp; do
            [[ -n "$kp" ]] && aws ec2 delete-key-pair --region us-west-2 --key-name "$kp" \
              && echo "Deleted key pair $kp"
          done

          echo "Sweep complete"
```

## IAM / OIDC Setup

One-time manual setup, documented but not automated:

### 1. OIDC Identity Provider

Create in AWS IAM console or CLI:
- Provider URL: `https://token.actions.githubusercontent.com`
- Audience: `sts.amazonaws.com`

### 2. IAM Role: `aoc-ci-test-role`

Trust policy:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:verkyyi/always-on-claude:*"
      }
    }
  }]
}
```

Permissions policy:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2ReadOnly",
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EC2WriteTestOnly",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:CreateKeyPair",
        "ec2:DeleteKeyPair",
        "ec2:CreateTags"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:RequestTag/Project": "aoc-ci-test"
        }
      }
    },
    {
      "Sid": "EC2WriteExistingTestResources",
      "Effect": "Allow",
      "Action": [
        "ec2:TerminateInstances",
        "ec2:DeleteSecurityGroup",
        "ec2:DeleteKeyPair"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "ec2:ResourceTag/Project": "aoc-ci-test"
        }
      }
    }
  ]
}
```

### 3. GitHub Configuration

- Add role ARN as repository variable: `AWS_CI_ROLE_ARN`
- Create GitHub environment `aws-integration-test` (optional: add protection rules)

## Cost Estimate

| Item | Frequency | Cost |
|------|-----------|------|
| Test run (t4g.micro ~3 min) | Daily | ~$0.001/day |
| Sweeper (describe calls only) | Hourly | Free tier |
| EBS (20GB, deleted with instance) | Per test | ~$0.0001 |
| **Monthly total** | | **< $0.10** |

## Future Extensions (out of scope)

- **Tier B:** `build-ami.sh` + `install-cloudwatch-alarms.sh` tests
- **SSH validation:** Verify SSH reachability and container boot (requires key in CI)
- **Multi-region:** Run tests across regions to verify region-agnostic behavior
