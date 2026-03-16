#!/bin/bash
# provision.sh — Run on your Mac to provision an EC2 instance and bootstrap it.
#
# One command from zero (assumes AWS CLI is configured):
#   bash <(curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/provision.sh)
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
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.medium}"
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
echo "    3. Launch an EC2 instance ($INSTANCE_TYPE, 30GB, Ubuntu 24.04)"
echo "    4. Install Docker + Claude Code on the instance"
echo "    5. Prompt you for GitHub + Claude authentication"
echo ""
echo "  Prerequisites:"
echo "    - AWS CLI configured with valid credentials (aws configure)"
echo "    - An AWS account (this will create billable resources)"
echo ""
echo "  Cost:"
echo "    - $INSTANCE_TYPE in $AWS_REGION: ~\$0.04/hr (~\$30/mo if left running)"
echo "    - 30GB gp3 EBS: ~\$2.40/mo"
echo "    - Stop the instance when not in use to save money"
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
    echo "  Skipping to auth setup. To start fresh, run destroy first."
    echo ""

    # Jump straight to auth
    info "Authentication setup"
    echo ""
    echo "  Setting up git, GitHub CLI, and Claude Code."
    echo "  This requires opening URLs in your browser."
    echo ""
    ssh -o StrictHostKeyChecking=no -t -i "$KEY_FILE" "${SSH_USER}@${PUBLIC_IP}" \
        "cd ~/dev-env && sg docker -c 'docker compose exec -it dev bash /home/dev/dev-env/setup-auth.sh'"

    echo ""
    echo "============================================"
    echo "  Done! Connect: ssh -i $KEY_FILE ${SSH_USER}@$PUBLIC_IP"
    echo "============================================"
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

# --- Launch instance --------------------------------------------------------

info "Launching instance"

USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
exec > /var/log/install.log 2>&1
su - ubuntu -c "NON_INTERACTIVE=1 bash -c 'curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/install.sh | bash'"
USERDATA
)

INSTANCE_ID=$(aws ec2 run-instances \
    --region "$AWS_REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --user-data "$USER_DATA" \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=30,VolumeType=gp3,DeleteOnTermination=true}' \
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

if ssh -o StrictHostKeyChecking=no -t -i "$KEY_FILE" "${SSH_USER}@${PUBLIC_IP}" \
    "cloud-init status --wait >/dev/null 2>&1"; then
    ok "Setup complete"
else
    echo "  WARN: cloud-init finished with errors"
    echo "  Check logs: ssh -i $KEY_FILE ${SSH_USER}@$PUBLIC_IP 'cat /var/log/install.log'"
fi

# Verify container is running
if ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" "${SSH_USER}@${PUBLIC_IP}" \
    "sg docker -c 'docker ps --format {{.Names}}' 2>/dev/null | grep -q claude-dev"; then
    ok "Container 'claude-dev' is running"
else
    echo "  WARN: Container not running — check /var/log/install.log on the instance"
fi

# --- Interactive auth (needs browser) ---------------------------------------

info "Authentication setup"

echo ""
echo "  Now we'll set up git, GitHub CLI, and Claude Code."
echo "  This requires opening URLs in your browser."
echo ""

ssh -o StrictHostKeyChecking=no -t -i "$KEY_FILE" "${SSH_USER}@${PUBLIC_IP}" \
    "cd ~/dev-env && sg docker -c 'docker compose exec -it dev bash /home/dev/dev-env/setup-auth.sh'" </dev/tty

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
echo "  To tear down:"
echo "    curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/destroy.sh | bash"
echo ""
