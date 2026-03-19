#!/bin/bash
# provision.sh — Run on your Mac to provision an EC2 instance and bootstrap it.
#
# One command from zero (assumes AWS CLI is configured):
#   bash <(curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/scripts/deploy/provision.sh)
#
# What it does:
#   1. Creates/reuses an SSH key pair and security group
#   2. Launches EC2 instance with install.sh running via User Data
#   3. Waits for instance + setup (~60s)
#   4. SSHs in for interactive auth (git, GitHub CLI, Claude Code)
#
# Override defaults with env vars:
#   INSTANCE_NAME=my-dev KEY_NAME=my-key AWS_REGION=us-west-2 bash provision.sh

set -euo pipefail

# --- Config (override with env vars) ----------------------------------------

INSTANCE_NAME="${INSTANCE_NAME:-claude-dev}"
KEY_NAME="${KEY_NAME:-claude-dev-key}"
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t4g.small}"
SG_NAME="${SG_NAME:-claude-dev-sg}"
SSH_USER="${SSH_USER:-ubuntu}"
TAG="always-on-claude"

# --- Helpers ----------------------------------------------------------------

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
skip()  { echo "  SKIP: $* (already done)"; }
die()   { echo "ERROR: $*" >&2; exit 1; }

# --- Confirmation -----------------------------------------------------------

echo ""
echo "============================================"
echo "  always-on-claude provisioner"
echo "============================================"
echo ""
echo "  What this will do:"
echo "    1. Create an SSH key pair in AWS (if not exists)"
echo "    2. Create a security group allowing SSH from anywhere"
echo "    3. Launch an EC2 instance ($INSTANCE_TYPE, 20GB)"
echo "    4. Set up Claude Code workspace (~40s with pre-built AMI)"
echo ""
echo "  Prerequisites:"
echo "    - AWS CLI configured with valid credentials (aws configure)"
echo "    - An AWS account (this will create billable resources)"
echo ""
echo "  Cost:"
echo "    - $INSTANCE_TYPE in $AWS_REGION: ~\$0.017/hr (~\$12/mo if left running)"
echo "    - 20GB gp3 EBS: ~\$1.60/mo"
echo "    - Public IPv4: ~\$3.65/mo"
echo ""
echo "  Resources created (tagged Project=$TAG):"
echo "    - EC2 instance: $INSTANCE_NAME"
echo "    - Security group: $SG_NAME (SSH open to 0.0.0.0/0)"
echo "    - SSH key pair: $KEY_NAME"
echo ""
echo "  Tear down anytime:"
echo "    curl -fsSL https://raw.githubusercontent.com/.../destroy.sh | bash"
echo ""
if [[ -t 0 ]]; then
    read -rp "  Proceed? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "  Aborted."
        exit 0
    fi
else
    echo "  (piped mode — proceeding automatically in 5 seconds)"
    echo "  Ctrl+C to cancel."
    sleep 5
fi

# --- Preflight --------------------------------------------------------------

info "Preflight checks"

command -v aws &>/dev/null || die "AWS CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
command -v ssh &>/dev/null || die "SSH client not found."

aws sts get-caller-identity &>/dev/null || die "AWS credentials not configured. Run: aws configure"

ok "AWS CLI configured (region: $AWS_REGION)"

# --- Check for existing instance -------------------------------------------

info "Checking for existing instance"

EXISTING_ID=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters \
        "Name=tag:Project,Values=$TAG" \
        "Name=tag:Name,Values=$INSTANCE_NAME" \
        "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null || echo "None")

if [[ "$EXISTING_ID" != "None" && -n "$EXISTING_ID" ]]; then
    PUBLIC_IP=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --instance-ids "$EXISTING_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)
    KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"
    ok "Instance '$INSTANCE_NAME' already running: $EXISTING_ID ($PUBLIC_IP)"
    echo ""
    echo "  Connect: ssh -i $KEY_FILE ${SSH_USER}@$PUBLIC_IP"
    echo "  To start fresh, run destroy first."
    exit 0
fi

skip "No existing instance found — creating new one"

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
        --key-type ed25519 \
        --region "$AWS_REGION" \
        --query 'KeyMaterial' \
        --output text > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    ok "Created key pair and saved to $KEY_FILE"
fi

# --- Security group ---------------------------------------------------------

info "Security group"

SG_ID=$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --filters "Name=group-name,Values=$SG_NAME" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "None")

if [[ "$SG_ID" != "None" && -n "$SG_ID" ]]; then
    ok "Security group '$SG_NAME' exists: $SG_ID"
else
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
fi

# --- Find AMI ---------------------------------------------------------------

info "Finding AMI"

# Determine architecture from instance type (t4g/m7g/c7g = arm64, otherwise x86_64)
case "$INSTANCE_TYPE" in
    *g.*|*gd.*) AMI_ARCH="arm64" ;;
    *)          AMI_ARCH="amd64" ;;
esac

# Try pre-built AMI first (tagged by build-ami.sh), then fall back to stock Ubuntu
CUSTOM_AMI=$(aws ec2 describe-images \
    --region "$AWS_REGION" \
    --filters "Name=tag:Project,Values=$TAG" "Name=state,Values=available" "Name=is-public,Values=true" \
        "Name=architecture,Values=${AMI_ARCH/amd64/x86_64}" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text 2>/dev/null || echo "None")

if [[ "$CUSTOM_AMI" != "None" && -n "$CUSTOM_AMI" ]]; then
    AMI_ID="$CUSTOM_AMI"
    USE_CUSTOM_AMI=1
    ok "Pre-built AMI: $AMI_ID ($AMI_ARCH, fast path — ~40s)"
else
    AMI_ID=$(aws ec2 describe-images \
        --owners 099720109477 \
        --region "$AWS_REGION" \
        --filters \
            "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${AMI_ARCH}-server-*" \
            "Name=state,Values=available" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text)
    USE_CUSTOM_AMI=0
    ok "Stock Ubuntu AMI: $AMI_ID ($AMI_ARCH, full install — ~90s)"
fi

[[ "$AMI_ID" == "None" || -z "$AMI_ID" ]] && die "Could not find any suitable AMI in $AWS_REGION"

# --- Launch instance --------------------------------------------------------

info "Launching instance"

if [[ "$USE_CUSTOM_AMI" == "1" ]]; then
    # Pre-built AMI: just start the container and update repo
    USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
exec > /var/log/install.log 2>&1
su - ubuntu -c 'cd ~/dev-env && git pull --ff-only 2>/dev/null; sudo --preserve-env=HOME docker compose up -d'
USERDATA
)
else
    # Stock Ubuntu: full install
    USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
exec > /var/log/install.log 2>&1
su - ubuntu -c "NON_INTERACTIVE=1 bash -c 'curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/scripts/deploy/install.sh | bash'"
USERDATA
)
fi

INSTANCE_ID=$(aws ec2 run-instances \
    --region "$AWS_REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --user-data "$USER_DATA" \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3,DeleteOnTermination=true}' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Project,Value=$TAG}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

ok "Instance launched: $INSTANCE_ID"
echo "  install.sh is running via User Data in the background..."

# --- Wait for instance + SSH ------------------------------------------------

info "Waiting for instance"

aws ec2 wait instance-running \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

[[ -z "$PUBLIC_IP" || "$PUBLIC_IP" == "None" ]] && die "Instance has no public IP"
ok "Running: $PUBLIC_IP"

echo "  Waiting for SSH..."
for i in $(seq 1 30); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
        -i "$KEY_FILE" "${SSH_USER}@${PUBLIC_IP}" "echo ok" &>/dev/null 2>&1; then
        ok "SSH is ready"
        break
    fi
    if [[ $i -eq 30 ]]; then
        die "SSH not available after 150 seconds"
    fi
    sleep 3
done

# --- Wait for setup to complete ---------------------------------------------

info "Waiting for setup to complete"

echo "  install.sh started during boot — waiting for it to finish..."

# Wait for cloud-init (no -t flag, works without TTY)
ssh -o StrictHostKeyChecking=no -o BatchMode=yes -i "$KEY_FILE" "${SSH_USER}@${PUBLIC_IP}" \
    "cloud-init status --wait" >/dev/null 2>&1 || true

# Poll for container to be running (cloud-init done doesn't guarantee compose up finished)
echo "  Waiting for container..."
for i in $(seq 1 60); do
    if ssh -o StrictHostKeyChecking=no -o BatchMode=yes -i "$KEY_FILE" "${SSH_USER}@${PUBLIC_IP}" \
        "sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q claude-dev" 2>/dev/null; then
        ok "Container 'claude-dev' is running"
        break
    fi
    if [[ $i -eq 60 ]]; then
        echo "  WARN: Container not running after 3 minutes"
        echo "  Check logs: ssh -i $KEY_FILE ${SSH_USER}@$PUBLIC_IP 'cat /var/log/install.log'"
    fi
    sleep 3
done

# Write .env.workspace for slash commands that detect workspace type
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

cat > "$REPO_DIR/.env.workspace" <<EOF
# Provisioned $(date +%Y-%m-%d)
WORKSPACE_TYPE=ec2
INSTANCE_ID=$INSTANCE_ID
PUBLIC_IP=$PUBLIC_IP
REGION=$AWS_REGION
INSTANCE_TYPE=$INSTANCE_TYPE
INSTANCE_NAME=$INSTANCE_NAME
SSH_KEY=$KEY_FILE
SG_ID=$SG_ID
EOF

echo ""
echo "============================================"
echo "  Provisioning complete!"
echo "============================================"
echo ""
echo "  Instance:  $INSTANCE_ID"
echo "  Public IP: $PUBLIC_IP"
echo "  SSH key:   $KEY_FILE"
echo ""
echo "  Connect:"
echo "    ssh -i $KEY_FILE ${SSH_USER}@$PUBLIC_IP"
echo ""
echo "  First time? Run auth setup inside the container:"
echo "    1. SSH in: ssh -i $KEY_FILE ${SSH_USER}@$PUBLIC_IP"
echo "    2. Choose option [2] for container bash"
echo "    3. Run: bash ~/dev-env/scripts/deploy/setup-auth.sh"
echo ""
echo "  To tear down:"
echo "    bash <(curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/scripts/deploy/destroy.sh)"
echo ""
