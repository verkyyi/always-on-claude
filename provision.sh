#!/bin/bash
# provision.sh — Run on your laptop to provision an EC2 instance and bootstrap it.
#
# Truly one command from zero (assumes AWS CLI is configured):
#   curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/provision.sh | bash
#
# Or clone first and run locally:
#   bash provision.sh
#
# What it does:
#   1. Creates/reuses an SSH key pair
#   2. Finds the latest Ubuntu 24.04 AMI for your region
#   3. Deploys the CloudFormation stack
#   4. Waits for the instance to be ready
#   5. SSHs in and runs install.sh
#
# Override defaults with env vars:
#   STACK_NAME=my-dev KEY_NAME=my-key AWS_REGION=us-west-2 bash provision.sh

set -euo pipefail

# --- Config (override with env vars) ----------------------------------------

STACK_NAME="${STACK_NAME:-claude-dev}"
KEY_NAME="${KEY_NAME:-claude-dev-key}"
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.medium}"
SSH_USER="${SSH_USER:-ubuntu}"

# --- Helpers ----------------------------------------------------------------

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
die()   { echo "ERROR: $*" >&2; exit 1; }

# --- Preflight --------------------------------------------------------------

info "Preflight checks"

command -v aws &>/dev/null || die "AWS CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
command -v ssh &>/dev/null || die "SSH client not found."

# Verify AWS credentials work
aws sts get-caller-identity &>/dev/null || die "AWS credentials not configured. Run: aws configure"

ok "AWS CLI configured (region: $AWS_REGION)"

# --- SSH Key Pair -----------------------------------------------------------

info "SSH key pair"

KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"

if aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$AWS_REGION" &>/dev/null 2>&1; then
    if [[ -f "$KEY_FILE" ]]; then
        ok "Key pair '$KEY_NAME' exists (local file: $KEY_FILE)"
    else
        echo "  Key pair '$KEY_NAME' exists in AWS but local file not found at $KEY_FILE"
        echo "  If you have the .pem file elsewhere, copy it to $KEY_FILE"
        echo "  Or delete the key pair and re-run: aws ec2 delete-key-pair --key-name $KEY_NAME --region $AWS_REGION"
        exit 1
    fi
else
    echo "  Creating key pair '$KEY_NAME'..."
    mkdir -p ~/.ssh
    aws ec2 create-key-pair \
        --key-name "$KEY_NAME" \
        --region "$AWS_REGION" \
        --query 'KeyMaterial' \
        --output text > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    ok "Created key pair and saved to $KEY_FILE"
fi

# --- Find latest Ubuntu 24.04 AMI ------------------------------------------

info "Finding Ubuntu 24.04 AMI"

AMI_ID=$(aws ec2 describe-images \
    --owners 099720109477 \
    --region "$AWS_REGION" \
    --filters \
        "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
        "Name=state,Values=available" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text)

[[ "$AMI_ID" == "None" || -z "$AMI_ID" ]] && die "Could not find Ubuntu 24.04 AMI in $AWS_REGION"
ok "AMI: $AMI_ID"

# --- CloudFormation stack ---------------------------------------------------

info "CloudFormation stack"

# Check if stack already exists
stack_status=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [[ "$stack_status" == "CREATE_COMPLETE" || "$stack_status" == "UPDATE_COMPLETE" ]]; then
    ok "Stack '$STACK_NAME' already exists ($stack_status)"
else
    if [[ "$stack_status" != "DOES_NOT_EXIST" && "$stack_status" != "" ]]; then
        echo "  Stack exists with status: $stack_status"
        echo "  Delete it first: aws cloudformation delete-stack --stack-name $STACK_NAME --region $AWS_REGION"
        exit 1
    fi

    # We need the CloudFormation template. Try local copy first, then download.
    if [[ -f "cloudformation.yml" ]]; then
        CF_TEMPLATE="file://cloudformation.yml"
    else
        echo "  Downloading cloudformation.yml..."
        curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/cloudformation.yml -o /tmp/aoc-cloudformation.yml
        CF_TEMPLATE="file:///tmp/aoc-cloudformation.yml"
    fi

    # Patch the AMI into the template's mappings (the template has a hardcoded AMI for us-east-1)
    # Instead, we'll override via a parameter — but the template doesn't support that.
    # Simplest: use the template as-is for us-east-1, or create a modified version for other regions.
    # For now, we'll create the stack with the template and let it use its built-in AMI mapping.
    # If the region isn't in the mapping, CloudFormation will fail with a clear error.

    echo "  Creating stack '$STACK_NAME'..."
    aws cloudformation create-stack \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION" \
        --template-body "$CF_TEMPLATE" \
        --parameters \
            ParameterKey=KeyPairName,ParameterValue="$KEY_NAME"

    echo "  Waiting for stack to complete (this takes 2-3 minutes)..."
    aws cloudformation wait stack-create-complete \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION"

    ok "Stack created"
fi

# --- Get instance IP --------------------------------------------------------

info "Instance details"

PUBLIC_IP=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`PublicIP`].OutputValue' \
    --output text)

[[ -z "$PUBLIC_IP" || "$PUBLIC_IP" == "None" ]] && die "Could not get instance IP from stack outputs"
ok "Public IP: $PUBLIC_IP"

# --- Wait for SSH to be available -------------------------------------------

info "Waiting for SSH"

echo "  Waiting for instance to accept SSH connections..."
for i in $(seq 1 30); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
        -i "$KEY_FILE" "${SSH_USER}@${PUBLIC_IP}" "echo ok" &>/dev/null 2>&1; then
        ok "SSH is ready"
        break
    fi
    if [[ $i -eq 30 ]]; then
        die "SSH not available after 150 seconds. Check the instance and security group."
    fi
    sleep 5
done

# --- Run install.sh on the instance ----------------------------------------

info "Running install.sh on the instance"

TAILSCALE="${TAILSCALE:-0}"

echo ""
echo "  Connecting to ${SSH_USER}@${PUBLIC_IP}..."
echo "  The install script will run automatically."
if [[ "$TAILSCALE" == "1" ]]; then
    echo "  You'll be prompted for Tailscale auth, git config, and Claude login."
else
    echo "  You'll be prompted for git config and Claude login."
fi
echo ""

if ssh -o StrictHostKeyChecking=no -t -i "$KEY_FILE" "${SSH_USER}@${PUBLIC_IP}" \
    "export TAILSCALE=$TAILSCALE && curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/install.sh | bash"; then
    echo ""
    echo "============================================"
    echo "  Provisioning complete!"
    echo "============================================"
else
    echo ""
    echo "============================================"
    echo "  Remote setup failed."
    echo "============================================"
    echo ""
    echo "  SSH in to debug: ssh -i $KEY_FILE ${SSH_USER}@$PUBLIC_IP"
    echo "  Re-run install:  curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/install.sh | bash"
    exit 1
fi
echo ""
echo "  Instance IP: $PUBLIC_IP"
echo "  SSH key:     $KEY_FILE"
echo "  Stack:       $STACK_NAME"
echo ""
echo "  Connect via SSH:"
echo "    ssh -i $KEY_FILE ${SSH_USER}@$PUBLIC_IP"
echo ""
if [[ "$TAILSCALE" == "1" ]]; then
    echo "  Or via Tailscale (after setup):"
    echo "    ssh ${SSH_USER}@<your-tailscale-hostname>"
    echo ""
fi
echo "  To tear down everything:"
echo "    aws cloudformation delete-stack --stack-name $STACK_NAME --region $AWS_REGION"
echo ""
