You are orchestrating the provisioning of an always-on Claude Code workspace on AWS. You will run all commands yourself, only pausing when the user needs to do something in a browser.

## Context

- AWS CLI configured: !`aws sts get-caller-identity 2>&1 | head -5`
- AWS region: !`aws configure get region 2>/dev/null || echo "not set"`
- Existing SSH keys: !`ls ~/.ssh/*.pem 2>/dev/null || echo "none"`
- Existing CloudFormation stacks: !`aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --query 'StackSummaries[].StackName' --output text 2>/dev/null || echo "error — check AWS CLI"`

---

## Before you start

If the AWS CLI context above shows an error or is not configured, stop and help the user set it up before proceeding. They need `aws configure` with a valid access key, secret, and region.

If `$ARGUMENTS` is provided, parse it for preferences (e.g. region, instance type, stack name, `tailscale`). Anything not specified uses defaults.

---

## Step 1 — Collect preferences

Ask the user ONE question with sensible defaults. Show what you'll create and let them confirm or adjust:

```
I'll provision an always-on Claude Code server with these settings:

  Region:        us-east-1
  Instance type: t3.medium
  Stack name:    claude-dev
  SSH key:       claude-dev-key
  Tailscale:     no

Press Enter to proceed, or tell me what to change.
```

Adjust defaults based on context (e.g. if AWS region is already configured, use that). If `$ARGUMENTS` mentions `tailscale`, set Tailscale to yes. If a stack with the default name already exists, suggest a different name or ask if they want to reuse it.

---

## Step 2 — SSH key pair

```bash
# Check if key exists in AWS
aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" 2>/dev/null
```

- **Exists + local .pem file found**: skip, tell user
- **Exists but no local file**: stop — tell user to find the .pem or delete the key pair
- **Doesn't exist**: create it:

```bash
aws ec2 create-key-pair --key-name "$KEY_NAME" --region "$REGION" --query 'KeyMaterial' --output text > ~/.ssh/$KEY_NAME.pem
chmod 600 ~/.ssh/$KEY_NAME.pem
```

---

## Step 3 — Find Ubuntu 24.04 AMI

```bash
aws ec2 describe-images \
    --owners 099720109477 \
    --region "$REGION" \
    --filters \
        "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
        "Name=state,Values=available" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text
```

If this returns `None`, the region may not have the AMI. Tell the user and suggest a different region.

---

## Step 4 — Deploy CloudFormation

Check if the stack already exists and is healthy:
- `CREATE_COMPLETE` or `UPDATE_COMPLETE` → skip, reuse it
- `ROLLBACK_COMPLETE` or `DELETE_FAILED` → delete it first, then recreate
- `*_IN_PROGRESS` → wait for it to finish, then assess
- Doesn't exist → create it

To create:
```bash
# Download template if not available locally
curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/cloudformation.yml -o /tmp/aoc-cloudformation.yml

aws cloudformation create-stack \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --template-body file:///tmp/aoc-cloudformation.yml \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters \
        ParameterKey=KeyPairName,ParameterValue="$KEY_NAME"
```

Then wait:
```bash
aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" --region "$REGION"
```

Tell the user "Creating infrastructure... this takes 2-3 minutes." while waiting.

---

## Step 5 — Get instance IP

```bash
aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`PublicIP`].OutputValue' \
    --output text
```

---

## Step 6 — Wait for SSH

Poll until SSH is available (max 30 attempts, 5s apart):

```bash
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes -i ~/.ssh/$KEY_NAME.pem ubuntu@$IP "echo ok"
```

---

## Step 7 — Remote setup via SSH

Run the install steps remotely. Use `ssh -t -i KEY ubuntu@IP "commands"` for each group. Set `TAILSCALE=1` in the remote environment if the user chose Tailscale.

**8a — System packages + Docker:**
```bash
ssh -t -i $KEY ubuntu@$IP "sudo apt-get update -qq && \
    (command -v docker &>/dev/null || curl -fsSL https://get.docker.com | sh) && \
    (command -v tmux &>/dev/null || sudo apt-get install -y -qq tmux) && \
    (dpkg -s at &>/dev/null 2>&1 || sudo apt-get install -y -qq at) && \
    (docker compose version &>/dev/null 2>&1 || sudo apt-get install -y -qq docker-compose-plugin) && \
    (id -nG ubuntu | grep -qw docker || sudo usermod -aG docker ubuntu) && \
    (systemctl is-active --quiet atd 2>/dev/null || sudo systemctl enable --now atd)"
```

**8b — Tailscale (only if enabled):**
```bash
ssh -t -i $KEY ubuntu@$IP "command -v tailscale &>/dev/null || curl -fsSL https://tailscale.com/install.sh | sh"
```

**8c — Clone repo + host dirs:**
```bash
ssh -t -i $KEY ubuntu@$IP 'DEV_ENV=$HOME/dev-env && \
    ([ -d "$DEV_ENV/.git" ] && git -C "$DEV_ENV" pull --ff-only || git clone https://github.com/verkyyi/always-on-claude.git "$DEV_ENV") && \
    mkdir -p ~/.claude/commands ~/.claude/debug ~/projects ~/overnight/logs ~/.gitconfig.d ~/.ssh && \
    [ -f ~/.claude.json ] || touch ~/.claude.json && \
    [ -f ~/.ssh/known_hosts ] || touch ~/.ssh/known_hosts && \
    cp "$DEV_ENV"/commands/*.md ~/.claude/commands/ 2>/dev/null; \
    chmod +x "$DEV_ENV"/*.sh 2>/dev/null; true'
```

**8d — Shell integration:**
```bash
ssh -t -i $KEY ubuntu@$IP 'grep -q "ssh-login.sh" ~/.bash_profile 2>/dev/null || echo -e "\n# Auto-launch Claude Code on SSH login\nsource ~/dev-env/ssh-login.sh" >> ~/.bash_profile'
```

**8e — Cron:**
```bash
ssh -t -i $KEY ubuntu@$IP 'crontab -l 2>/dev/null | grep -q "trigger-watcher.sh" || (crontab -l 2>/dev/null; echo "* * * * * bash ~/dev-env/trigger-watcher.sh >> ~/overnight/trigger-watcher.log 2>&1") | crontab -'
```

**8f — Docker pull + start:**
```bash
ssh -t -i $KEY ubuntu@$IP 'cd ~/dev-env && sg docker -c "docker pull ghcr.io/verkyyi/always-on-claude:latest && docker compose up -d"'
```

If pull fails, fallback:
```bash
ssh -t -i $KEY ubuntu@$IP 'cd ~/dev-env && sg docker -c "docker compose -f docker-compose.yml -f docker-compose.build.yml build && docker compose up -d"'
```

**8g — Fix permissions:**
```bash
ssh -t -i $KEY ubuntu@$IP 'cd ~/dev-env && sg docker -c "docker compose exec -T -u root dev bash -c \"chown -R dev:dev /home/dev/projects /home/dev/.claude /home/dev/overnight\""'
```

After each group, report progress to the user (e.g. "Docker installed. Pulling image...").

---

## Step 8 — Interactive auth (needs user)

Tell the user:

```
Infrastructure is ready! Now we need to set up authentication.
This requires you to open URLs in your browser.

I'll SSH you into the container where setup-auth.sh will run interactively.
```

If Tailscale is enabled, first do:
```bash
ssh -t -i $KEY ubuntu@$IP "sudo tailscale up --ssh"
```
Tell the user to open the Tailscale URL in their browser and authenticate. Then ask for a hostname and set it.

Then run the interactive auth:
```bash
ssh -t -i $KEY ubuntu@$IP 'cd ~/dev-env && sg docker -c "docker compose exec -it dev bash /home/dev/dev-env/setup-auth.sh"'
```

**IMPORTANT:** This is interactive — the user will see prompts for git config, `gh auth login`, and `claude login`. Tell them what to expect before running it.

---

## Step 9 — Verify + print summary

Run verification:
```bash
ssh -i $KEY ubuntu@$IP 'cd ~/dev-env && sg docker -c "docker ps --format {{.Names}}" | grep -q claude-dev && echo "container: ok" || echo "container: FAIL"'
```

Then print a clean summary:

```
Setup complete!

  Instance IP: $IP
  SSH key:     ~/.ssh/$KEY_NAME.pem
  Stack:       $STACK_NAME ($REGION)

  Connect:
    ssh -i ~/.ssh/$KEY_NAME.pem ubuntu@$IP

  [If Tailscale] Or via Tailscale:
    ssh ubuntu@$TAILSCALE_HOSTNAME

  The login menu will appear — press Enter for Claude Code.

  To tear down:
    aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION
```

---

## Error handling

- **CloudFormation in ROLLBACK_COMPLETE**: delete the stack and retry creation
- **SSH timeout after 30 tries**: check security group allows your IP, check instance is running
- **Docker pull fails**: fall back to local build, tell the user it will take a few extra minutes
- **Any SSH command fails**: show the error, suggest the user SSH in manually to debug
- **Key pair exists without local file**: don't create a new one — the instance won't accept it. Help user find the file or delete the AWS key pair first.

Do NOT blindly retry failed commands. Diagnose the error and take the appropriate corrective action, or ask the user for help.
