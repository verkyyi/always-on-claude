#!/bin/bash
# destroy.sh — Tear down always-on-claude EC2 resources.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/scripts/deploy/destroy.sh | bash
#
# Finds resources by Project=always-on-claude tag and deletes them.
# Prompts for confirmation before each destructive action.

set -euo pipefail

# --- Config -----------------------------------------------------------------

AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}"
TAG="always-on-claude"
KEY_NAME="${KEY_NAME:-claude-dev-key}"

# --- Helpers ----------------------------------------------------------------

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
die()   { echo "ERROR: $*" >&2; exit 1; }

# --- Preflight --------------------------------------------------------------

info "Preflight checks"

command -v aws &>/dev/null || die "AWS CLI not found"
aws sts get-caller-identity &>/dev/null || die "AWS credentials not configured. Run: aws configure"

ok "AWS CLI configured (region: $AWS_REGION)"

# --- Find resources ---------------------------------------------------------

info "Finding resources"

# Find instances
INSTANCE_IDS=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters \
        "Name=tag:Project,Values=$TAG" \
        "Name=instance-state-name,Values=running,stopped,pending" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null || echo "")

# Find security groups
SG_IDS=$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --filters "Name=tag:Project,Values=$TAG" \
    --query 'SecurityGroups[].GroupId' \
    --output text 2>/dev/null || echo "")

# Check for key pair
KEY_EXISTS="no"
if aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$AWS_REGION" &>/dev/null 2>&1; then
    KEY_EXISTS="yes"
fi

KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"

# --- Show what we found -----------------------------------------------------

echo ""
if [[ -n "$INSTANCE_IDS" ]]; then
    echo "  Instances:      $INSTANCE_IDS"
else
    echo "  Instances:      none"
fi
if [[ -n "$SG_IDS" ]]; then
    echo "  Security groups: $SG_IDS"
else
    echo "  Security groups: none"
fi
echo "  Key pair:        $KEY_NAME ($KEY_EXISTS in AWS, $(if [[ -f $KEY_FILE ]]; then echo "local file exists"; else echo "no local file"; fi))"

if [[ -z "$INSTANCE_IDS" && -z "$SG_IDS" && "$KEY_EXISTS" == "no" ]]; then
    echo ""
    echo "  Nothing to delete."
    exit 0
fi

echo ""
read -rp "  Delete all of these? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "  Aborted."
    exit 0
fi

# --- Terminate instances ----------------------------------------------------

if [[ -n "$INSTANCE_IDS" ]]; then
    info "Terminating instances"

    aws ec2 terminate-instances \
        --region "$AWS_REGION" \
        --instance-ids $INSTANCE_IDS >/dev/null

    echo "  Waiting for termination..."
    aws ec2 wait instance-terminated \
        --region "$AWS_REGION" \
        --instance-ids $INSTANCE_IDS

    ok "Instances terminated"
fi

# --- Delete security groups -------------------------------------------------

if [[ -n "$SG_IDS" ]]; then
    info "Deleting security groups"

    for sg in $SG_IDS; do
        aws ec2 delete-security-group \
            --region "$AWS_REGION" \
            --group-id "$sg" 2>/dev/null && ok "Deleted $sg" || echo "  WARN: Could not delete $sg (may still be in use, retry in a minute)"
    done
fi

# --- Delete key pair --------------------------------------------------------

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

# --- Done -------------------------------------------------------------------

echo ""
echo "============================================"
echo "  Teardown complete."
echo "============================================"
echo ""
echo "  To re-provision:"
echo "    curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/scripts/deploy/provision.sh | bash"
echo ""
