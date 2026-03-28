You are orchestrating the provisioning of an always-on Claude Code workspace on AWS. You will run all commands yourself, only pausing when the user needs to do something in a browser.

## Context

- AWS CLI configured: !`aws sts get-caller-identity 2>&1 | head -5`
- AWS region: !`aws configure get region 2>/dev/null || echo "not set"`
- Existing SSH keys: !`find ~/.ssh ~/ -maxdepth 1 -name "*.pem" 2>/dev/null || echo "none"`
- Existing instances: !`aws ec2 describe-instances --region "$(aws configure get region 2>/dev/null || echo us-east-1)" --filters "Name=tag:Project,Values=always-on-claude" "Name=instance-state-name,Values=running,pending" --query "Reservations[].Instances[].[InstanceId,PublicIpAddress,Tags[?Key=='Name'].Value|[0]]" --output text 2>/dev/null || echo "error — check AWS CLI"`

---

## Before you start

If the AWS CLI context above shows an error or is not configured, stop and help the user set it up before proceeding. They need `aws configure` with a valid access key, secret, and region.

If an existing instance is found, ask if they want to reuse it (skip to auth) or destroy and recreate.

If `$ARGUMENTS` is provided, parse it for preferences (e.g. region, instance type, name). Anything not specified uses defaults.

---

## Step 1 — Determine settings and proceed

Use sensible defaults. If `$ARGUMENTS` specifies preferences (region, instance type, name), use those. Otherwise use defaults. If an existing instance with the default name exists, auto-increment (e.g. `claude-dev-2`).

Show the settings and ask the user to confirm or adjust:

```
Provisioning an always-on Claude Code server:

  Region:        us-east-1
  Instance type: t4g.small
  Instance name: claude-dev-2
  SSH key:       claude-dev-2-key

Say "go" to proceed, or tell me what to change.
```

Adjust defaults based on context (e.g. if AWS region is already configured, use that).

---

## Step 2 — SSH key pair

```bash
aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" 2>/dev/null
```

- **Exists + local .pem file found**: skip
- **Exists but no local file**: stop — tell user to find the .pem or delete the key pair
- **Doesn't exist**: create it. Save to `~/.ssh/` if writable, otherwise `~/`:

```bash
KEY_DIR=~/.ssh
[[ -w "$KEY_DIR" ]] || KEY_DIR=~
aws ec2 create-key-pair --key-name "$KEY_NAME" --region "$REGION" --query 'KeyMaterial' --output text > "$KEY_DIR/$KEY_NAME.pem"
chmod 600 "$KEY_DIR/$KEY_NAME.pem"
```

---

## Step 3 — Security group

```bash
SG_ID=$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=group-name,Values=claude-dev-sg" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
```

- **Exists**: reuse it
- **Doesn't exist**: create + authorize SSH + tag with `Project=always-on-claude`

---

## Step 4 — Find AMI

Try a pre-built AMI first (tagged `Project=always-on-claude`, matching architecture). Fall back to stock Ubuntu 24.04 if none found.

```bash
# Determine arch from instance type: *g.* = arm64, otherwise x86_64
# Try pre-built AMI
aws ec2 describe-images --region "$REGION" \
    --filters "Name=tag:Project,Values=always-on-claude" "Name=state,Values=available" "Name=is-public,Values=true" \
        "Name=architecture,Values=$ARCH" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' --output text

# Fall back to stock Ubuntu
aws ec2 describe-images --owners 099720109477 --region "$REGION" \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-$ARCH-server-*" "Name=state,Values=available" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' --output text
```

---

## Step 5 — Launch instance

**If using a pre-built AMI**: launch WITHOUT `--user-data`. The AMI has a systemd service that starts the container on boot, and cloud-init injects the SSH key to the `dev` user automatically.

**If using stock Ubuntu**: launch WITH `--user-data` using multipart MIME to create the `dev` user via cloud-config and run install.sh:

```bash
USER_DATA=$(cat <<'USERDATA'
Content-Type: multipart/mixed; boundary="==BOUNDARY=="
MIME-Version: 1.0

--==BOUNDARY==
Content-Type: text/cloud-config; charset="us-ascii"
MIME-Version: 1.0

system_info:
  default_user:
    name: dev
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [sudo]
    homedir: /home/dev

--==BOUNDARY==
Content-Type: text/x-shellscript; charset="us-ascii"
MIME-Version: 1.0

#!/bin/bash
exec > /var/log/install.log 2>&1
su - dev -c "NON_INTERACTIVE=1 bash -c 'curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/scripts/deploy/install.sh | bash'"
--==BOUNDARY==--
USERDATA
)

aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --user-data "$USER_DATA" \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3,DeleteOnTermination=true}' \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=claude-dev},{Key=Project,Value=always-on-claude}]' \
    --query 'Instances[0].InstanceId' --output text
```

Tell the user what to expect based on AMI type:
- Pre-built: "Container starts via systemd (~40s)"
- Stock Ubuntu: "install.sh is running via User Data (~90s)"

---

## Step 6 — Wait for instance + SSH

```bash
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
```

Get public IP, then poll SSH:
```bash
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes -i ~/.ssh/$KEY_NAME.pem dev@$IP "echo ok"
```

---

## Step 7 — Wait for setup and verify

```bash
ssh -t -i $KEY dev@$IP "cloud-init status --wait >/dev/null 2>&1"
```

Wait for container to be running (systemd starts it after boot, may take a few seconds):
```bash
for i in $(seq 1 30); do
    ssh -i $KEY dev@$IP "docker ps --format {{.Names}} | grep -q claude-dev" 2>/dev/null && break
    sleep 2
done
```

Run a quick health check and report results:
```bash
ssh -i $KEY dev@$IP "echo '=== groups ===' && id -nG && echo '=== container ===' && docker ps --format '{{.Names}} ({{.Status}})' && echo '=== dev-env ===' && docker exec claude-dev test -d /home/dev/dev-env && echo 'mounted' || echo 'MISSING'"
```

Expected: `dev` in docker+sudo groups, container `claude-dev` running, dev-env mounted.

---

## Step 8 — Interactive auth

```bash
ssh -t -i $KEY dev@$IP "docker exec -it claude-dev bash /home/dev/dev-env/scripts/deploy/setup-auth.sh"
```

Tell the user what to expect before running it (git config, GitHub CLI, Claude login — each requires browser auth).

---

## Step 9 — Save workspace info

Write provisioning details to `.env.workspace.$INSTANCE_NAME` (gitignored via `.env.*` pattern):

```bash
cat > .env.workspace.$INSTANCE_NAME << EOF
# Provisioned $(date +%Y-%m-%d)
INSTANCE_ID=$INSTANCE_ID
PUBLIC_IP=$IP
REGION=$REGION
INSTANCE_TYPE=$INSTANCE_TYPE
INSTANCE_NAME=$INSTANCE_NAME
SSH_KEY=$KEY_DIR/$KEY_NAME.pem
SG_ID=$SG_ID
EOF
```

---

## Step 10 — SSH config

**Skip if `~/.ssh/config` is not writable** (e.g. provisioning from inside a container). Instead, show the user the SSH command with the full key path.

If writable, add (or update) an SSH config entry so the user can connect with just `ssh $INSTANCE_NAME`:

- If `~/.ssh/config` already has a `Host $INSTANCE_NAME` block, update the `HostName` to the new IP
- Otherwise, prepend a new block before the `Host *` wildcard entry:

```
Host $INSTANCE_NAME
    HostName $IP
    User dev
    IdentityFile $KEY_DIR/$KEY_NAME.pem
```

---

## Step 11 — Shell aliases

**Skip if shell config files are not writable** (e.g. provisioning from inside a container). Instead, include the connect commands in the summary.

If writable, add `cc` and `ccc` aliases to the user's shell config (`~/.zshrc` on macOS, `~/.bashrc` on Linux):

- If aliases already exist, update them
- Otherwise, append:

```bash
# Claude Code workspace shortcuts
alias cc="ssh -t $INSTANCE_NAME 'exec bash ~/dev-env/scripts/runtime/start-claude.sh'"
alias ccc="ssh -t $INSTANCE_NAME 'NO_CLAUDE=1 exec bash -l'"
```

Tell the user to run `source ~/.zshrc` (or open a new terminal) to activate.

---

## Step 12 — Summary

```
Provisioning complete!

  Instance:  $INSTANCE_ID
  Public IP: $IP

  Connect:
    ssh -t -i $KEY_DIR/$KEY_NAME.pem dev@$IP 'bash ~/dev-env/scripts/runtime/start-claude.sh'

  To tear down:
    /destroy $INSTANCE_NAME
```

If SSH config and aliases were set up (Steps 10-11), also show the short forms (`cc`, `ccc`, `ssh $INSTANCE_NAME`).

---

## Error handling

- **Instance already exists**: ask if reuse or recreate
- **SSH timeout**: check security group, check instance state
- **cloud-init errors**: show /var/log/install.log
- **Docker pull fails**: install.sh falls back to local build automatically
- **Key pair exists without local file**: help user find it or delete the AWS key pair

Do NOT blindly retry failed commands. Diagnose and fix, or ask the user.
