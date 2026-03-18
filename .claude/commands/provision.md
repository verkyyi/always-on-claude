You are orchestrating the provisioning of an always-on Claude Code workspace on AWS. You will run all commands yourself, only pausing when the user needs to do something in a browser.

## Context

- AWS CLI configured: !`aws sts get-caller-identity 2>&1 | head -5`
- AWS region: !`aws configure get region 2>/dev/null || echo "not set"`
- Existing SSH keys: !`ls ~/.ssh/*.pem 2>/dev/null || echo "none"`
- Existing instances: !`aws ec2 describe-instances --filters "Name=tag:Project,Values=always-on-claude" "Name=instance-state-name,Values=running,pending" --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress,Tags[?Key==\x60Name\x60].Value|[0]]' --output text 2>/dev/null || echo "error — check AWS CLI"`

---

## Before you start

If the AWS CLI context above shows an error or is not configured, stop and help the user set it up before proceeding. They need `aws configure` with a valid access key, secret, and region.

If an existing instance is found, ask if they want to reuse it (skip to auth) or destroy and recreate.

If `$ARGUMENTS` is provided, parse it for preferences (e.g. region, instance type, name). Anything not specified uses defaults.

---

## Step 1 — Collect preferences

Ask the user ONE question with sensible defaults:

```
I'll provision an always-on Claude Code server:

  Region:        us-east-1
  Instance type: t3.medium
  Instance name: claude-dev
  SSH key:       claude-dev-key

Press Enter to proceed, or tell me what to change.
```

Adjust defaults based on context (e.g. if AWS region is already configured, use that).

---

## Step 2 — SSH key pair

```bash
aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" 2>/dev/null
```

- **Exists + local .pem file found**: skip
- **Exists but no local file**: stop — tell user to find the .pem or delete the key pair
- **Doesn't exist**: create it:

```bash
aws ec2 create-key-pair --key-name "$KEY_NAME" --region "$REGION" --query 'KeyMaterial' --output text > ~/.ssh/$KEY_NAME.pem
chmod 600 ~/.ssh/$KEY_NAME.pem
```

---

## Step 3 — Security group

```bash
SG_ID=$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=group-name,Values=claude-dev-sg" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
```

- **Exists**: reuse it
- **Doesn't exist**: create + authorize SSH + tag with `Project=always-on-claude`

---

## Step 4 — Find Ubuntu 24.04 AMI

```bash
aws ec2 describe-images \
    --owners 099720109477 --region "$REGION" \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" "Name=state,Values=available" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' --output text
```

---

## Step 5 — Launch instance

```bash
aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --user-data '#!/bin/bash
exec > /var/log/install.log 2>&1
su - ubuntu -c "NON_INTERACTIVE=1 bash -c '\''curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/install.sh | bash'\''"' \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=30,VolumeType=gp3,DeleteOnTermination=true}' \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=claude-dev},{Key=Project,Value=always-on-claude}]' \
    --query 'Instances[0].InstanceId' --output text
```

Tell the user "Instance launched — install.sh is running in the background via User Data."

---

## Step 6 — Wait for instance + SSH

```bash
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
```

Get public IP, then poll SSH:
```bash
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes -i ~/.ssh/$KEY_NAME.pem ubuntu@$IP "echo ok"
```

---

## Step 7 — Wait for setup

```bash
ssh -t -i $KEY ubuntu@$IP "cloud-init status --wait >/dev/null 2>&1"
```

Verify container is running:
```bash
ssh -i $KEY ubuntu@$IP "sg docker -c 'docker ps --format {{.Names}}' | grep -q claude-dev"
```

---

## Step 8 — Interactive auth

```bash
ssh -t -i $KEY ubuntu@$IP "cd ~/dev-env && sg docker -c 'docker compose exec -it dev bash /home/dev/dev-env/setup-auth.sh'"
```

Tell the user what to expect before running it (git config, GitHub CLI, Claude login — each requires browser auth).

---

## Step 9 — Summary

```
Provisioning complete!

  Instance:  $INSTANCE_ID
  Public IP: $IP
  SSH key:   ~/.ssh/$KEY_NAME.pem

  Connect:
    ssh -i ~/.ssh/$KEY_NAME.pem ubuntu@$IP

  To tear down:
    /destroy
```

---

## Error handling

- **Instance already exists**: ask if reuse or recreate
- **SSH timeout**: check security group, check instance state
- **cloud-init errors**: show /var/log/install.log
- **Docker pull fails**: install.sh falls back to local build automatically
- **Key pair exists without local file**: help user find it or delete the AWS key pair

Do NOT blindly retry failed commands. Diagnose and fix, or ask the user.
