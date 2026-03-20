#!/bin/bash
# build-ami.sh — Build a pre-baked AMI with Docker + Claude Code pre-installed.
#
# Usage:
#   bash build-ami.sh
#
# What it does:
#   1. Launches a temporary EC2 instance with stock Ubuntu 24.04
#   2. Runs install.sh to install everything
#   3. Creates an AMI from the instance
#   4. Makes the AMI public
#   5. Terminates the temporary instance
#
# The resulting AMI is tagged and can be found by provision.sh automatically.
# Run this whenever you update the Docker image or tools.
#
# Override defaults with env vars:
#   AWS_REGION=us-west-2 bash build-ami.sh

set -euo pipefail

# --- Config (from .env file, override with env vars) -------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/load-config.sh"

# AMI builds use their own instance type and volume size
INSTANCE_TYPE="${AMI_BUILD_INSTANCE_TYPE}"
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "manual")
AMI_NAME="always-on-claude-$(date +%Y%m%d)-${GIT_SHA}"

# --- Helpers ----------------------------------------------------------------

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
die()   { echo "ERROR: $*" >&2; exit 1; }

cleanup() {
    if [[ -n "${INSTANCE_ID:-}" ]]; then
        echo ""
        echo "  Cleaning up: terminating build instance $INSTANCE_ID..."
        aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# --- Preflight --------------------------------------------------------------

info "Preflight checks"

command -v aws &>/dev/null || die "AWS CLI not found"
aws sts get-caller-identity &>/dev/null || die "AWS credentials not configured"

KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"
[[ -f "$KEY_FILE" ]] || die "SSH key not found at $KEY_FILE — run provision.sh first to create it"
aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$AWS_REGION" &>/dev/null 2>&1 \
    || die "Key pair '$KEY_NAME' not found in AWS"

ok "AWS CLI configured (region: $AWS_REGION)"

# --- Check for existing AMI -------------------------------------------------

info "Checking for existing AMI"

EXISTING_AMI=$(aws ec2 describe-images \
    --owners self \
    --region "$AWS_REGION" \
    --filters "Name=tag:Project,Values=$TAG" "Name=state,Values=available" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text 2>/dev/null || echo "None")

if [[ "$EXISTING_AMI" != "None" && -n "$EXISTING_AMI" ]]; then
    echo "  Existing AMI found: $EXISTING_AMI"
    echo "  This will create a new AMI. The old one will remain until you delete it."
    echo ""
fi

# --- Find base Ubuntu AMI ---------------------------------------------------

info "Finding Ubuntu 24.04 base AMI"

BASE_AMI=$(aws ec2 describe-images \
    --owners 099720109477 \
    --region "$AWS_REGION" \
    --filters \
        "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
        "Name=state,Values=available" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text)

[[ "$BASE_AMI" == "None" || -z "$BASE_AMI" ]] && die "Could not find Ubuntu 24.04 AMI in $AWS_REGION"
ok "Base AMI: $BASE_AMI"

# --- Need a security group for the build instance ---------------------------

# SG_NAME is set by load-config.sh
SG_ID=$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --filters "Name=group-name,Values=$SG_NAME" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "None")

if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
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
        --tags Key=Project,Value="$TAG"
fi

# --- Launch temporary build instance ----------------------------------------

info "Launching build instance"

INSTANCE_ID=$(aws ec2 run-instances \
    --region "$AWS_REGION" \
    --image-id "$BASE_AMI" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$AMI_BUILD_VOLUME_SIZE,VolumeType=gp3,DeleteOnTermination=true}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=ami-builder},{Key=Project,Value=$TAG}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

ok "Build instance: $INSTANCE_ID"

aws ec2 wait instance-running \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

ok "Running: $PUBLIC_IP"

# --- Wait for SSH -----------------------------------------------------------

echo "  Waiting for SSH..."
for i in $(seq 1 30); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
        -i "$KEY_FILE" "ubuntu@${PUBLIC_IP}" "echo ok" &>/dev/null 2>&1; then
        ok "SSH is ready"
        break
    fi
    [[ $i -eq 30 ]] && die "SSH not available after 150 seconds"
    sleep 5
done

# --- Run install.sh on the build instance -----------------------------------

info "Running install.sh"

echo "  Installing Docker, Claude Code, pulling image..."
echo "  This takes 2-3 minutes..."

ssh -o StrictHostKeyChecking=no -o BatchMode=yes -i "$KEY_FILE" "ubuntu@${PUBLIC_IP}" \
    "NON_INTERACTIVE=1 bash -c 'curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/scripts/deploy/install.sh | bash'" \
    2>&1 | while IFS= read -r line; do echo "  $line"; done

ok "Install complete"

# --- Clean up instance for AMI snapshot -------------------------------------

info "Preparing instance for snapshot"

# Remove host-specific state that shouldn't be baked into the AMI
ssh -o StrictHostKeyChecking=no -o BatchMode=yes -i "$KEY_FILE" "dev@${PUBLIC_IP}" bash <<'CLEANUP'
# Remove SSH host keys (regenerated on boot)
sudo rm -f /etc/ssh/ssh_host_*

# Clear cloud-init state so it runs fresh on new instances
sudo cloud-init clean --logs

# Remove bash history
rm -f ~/.bash_history
history -c

# Stop the container (will be started via User Data on new instances)
cd ~/dev-env && sudo docker compose stop 2>/dev/null || true
CLEANUP

ok "Instance cleaned for snapshot"

# --- Create AMI -------------------------------------------------------------

info "Creating AMI"

echo "  Snapshotting instance (this takes 3-5 minutes)..."

AMI_ID=$(aws ec2 create-image \
    --region "$AWS_REGION" \
    --instance-id "$INSTANCE_ID" \
    --name "$AMI_NAME" \
    --description "Always-on Claude Code workspace - Ubuntu 24.04 + Docker + Claude Code" \
    --tag-specifications "ResourceType=image,Tags=[{Key=Name,Value=$AMI_NAME},{Key=Project,Value=$TAG}]" \
    --query 'ImageId' \
    --output text)

ok "AMI creation started: $AMI_ID"

aws ec2 wait image-available \
    --region "$AWS_REGION" \
    --image-ids "$AMI_ID"

ok "AMI available: $AMI_ID"

# --- Make AMI public --------------------------------------------------------

info "Making AMI public"

aws ec2 modify-image-attribute \
    --region "$AWS_REGION" \
    --image-id "$AMI_ID" \
    --launch-permission "Add=[{Group=all}]"

ok "AMI is now public"

# --- Terminate build instance (handled by trap, but be explicit) ------------

info "Cleaning up"

aws ec2 terminate-instances \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" >/dev/null
INSTANCE_ID=""  # prevent trap from re-terminating

ok "Build instance terminated"

# --- Deregister old AMIs (optional) -----------------------------------------

if [[ "$EXISTING_AMI" != "None" && -n "$EXISTING_AMI" && "$EXISTING_AMI" != "$AMI_ID" ]]; then
    echo ""
    echo "  Old AMI still exists: $EXISTING_AMI"
    echo "  To deregister it:"
    echo "    aws ec2 deregister-image --image-id $EXISTING_AMI --region $AWS_REGION"
fi

# --- Done -------------------------------------------------------------------

echo ""
echo "============================================"
echo "  AMI build complete!"
echo "============================================"
echo ""
echo "  AMI ID:  $AMI_ID"
echo "  Name:    $AMI_NAME"
echo "  Region:  $AWS_REGION"
echo "  Public:  yes"
echo ""
echo "  provision.sh will automatically find and use this AMI."
echo ""
echo "  To copy to another region:"
echo "    aws ec2 copy-image --source-region $AWS_REGION --source-image-id $AMI_ID \\"
echo "      --region TARGET_REGION --name $AMI_NAME"
echo ""
