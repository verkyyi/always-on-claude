You are guiding a user through deploying an always-on Claude Code workspace end-to-end. This is the single entry point for all deployments — EC2 or local Mac. You will run all commands yourself, only pausing when the user needs to do something in a browser or System Settings.

## Context

- OS: !`uname -s`
- Architecture: !`uname -m`
- Existing workspace: !`cat .env.workspace 2>/dev/null || echo "NOT FOUND"`
- AWS CLI: !`aws sts get-caller-identity 2>&1 | head -3 || echo "not configured"`
- Docker: !`docker info 2>&1 | head -3 || echo "not installed"`

---

## Before you start

Parse `$ARGUMENTS` for flags and preferences:
- `--from-scratch` — destroy any existing workspace and start fresh
- `--ec2` or `--aws` — force EC2 deployment (skip target selection)
- `--local` or `--mac` — force local Mac deployment (skip target selection)
- Region, instance type, name, etc. can also be specified (e.g. `--region us-west-2`, `t3.medium`)

If `--from-scratch` is specified and a workspace already exists, confirm with the user, then tear down the existing workspace before proceeding:
- For EC2: follow the `/destroy` workflow (terminate instance, delete SG, optionally delete key pair)
- For local Mac: follow the `/destroy-local` workflow (stop container, remove launchd agents, clean up shell integration)

If an existing workspace is detected (`.env.workspace` exists) and `--from-scratch` is NOT specified, show the current workspace info and ask:
```
An existing workspace was found:

  Type:       $WORKSPACE_TYPE
  [Instance:  $INSTANCE_ID ($PUBLIC_IP)]  ← EC2 only
  [Hostname:  $HOSTNAME]                  ← Mac only

Options:
  1. Re-run setup (idempotent — safe to re-run, picks up where it left off)
  2. Destroy and start fresh (--from-scratch)
  3. Cancel

Choose [1/2/3]:
```

---

## Step 1 — Choose deployment target

If the target wasn't specified via flags, detect or ask:

**If running on macOS** (`uname -s` = Darwin):
```
Where would you like to deploy?

  1. This Mac — run the workspace locally (good for Mac mini / Mac Studio)
  2. AWS EC2  — launch a cloud instance (good for always-on from any device)

Choose [1/2]:
```

**If running on Linux**: default to EC2 (this IS the server). If they're running this on an existing EC2 instance, suggest re-running `/provision` setup instead.

**If AWS CLI is not configured and EC2 is selected**: stop and help the user run `aws configure` first. They need a valid access key, secret, and default region.

---

## Step 2 — Collect configuration

### For EC2 deployment:

Detect sensible defaults from the environment:
```bash
aws configure get region 2>/dev/null || echo "us-east-1"
ls ~/.ssh/*.pem 2>/dev/null || echo "none"
aws ec2 describe-instances --filters "Name=tag:Project,Values=always-on-claude" "Name=instance-state-name,Values=running,pending" --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress,Tags[?Key==`Name`].Value|[0]]' --output text 2>/dev/null || echo "none"
```

Present ONE confirmation prompt with all settings:
```
I'll deploy an always-on Claude Code workspace to AWS:

  Region:        us-east-1
  Instance type: t4g.small (ARM, ~$0.017/hr ≈ $12/mo)
  Instance name: claude-dev
  SSH key:       claude-dev-key
  Storage:       20GB gp3 (~$1.60/mo)
  Public IPv4:   ~$3.65/mo

  Estimated cost: ~$17/mo (if left running 24/7)

Press Enter to proceed, or tell me what to change.
```

### For local Mac deployment:

```
I'll set up this Mac as an always-on Claude Code workspace:

  Hostname:  (detected)
  Docker:    (detected status)

  What I'll do:
    1. Install prerequisites (tmux, git, gh, node, etc.)
    2. Install/verify Docker
    3. Install Claude Code CLI
    4. Pull and start the workspace container
    5. Set up authentication (git, GitHub, Claude)
    6. Enable SSH for remote access
    7. Configure auto-start on boot

Press Enter to proceed, or tell me what to change.
```

---

## EC2 Deployment Flow

Follow these steps in order. Report progress after each step.

### Step 3E — SSH key pair

```bash
aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" 2>/dev/null
```

- **Exists + local .pem file found**: skip
- **Exists but no local file**: stop — tell user to find the .pem or delete the key pair
- **Doesn't exist**: create it:

```bash
mkdir -p ~/.ssh
aws ec2 create-key-pair --key-name "$KEY_NAME" --key-type ed25519 --region "$REGION" --query 'KeyMaterial' --output text > ~/.ssh/$KEY_NAME.pem
chmod 600 ~/.ssh/$KEY_NAME.pem
```

### Step 4E — Security group

```bash
SG_ID=$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=group-name,Values=claude-dev-sg" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
```

- **Exists**: reuse it
- **Doesn't exist**: create + authorize SSH (port 22 from 0.0.0.0/0) + tag with `Project=always-on-claude`

### Step 5E — Find AMI

Determine architecture from instance type (t4g/m7g/c7g/etc. = arm64, otherwise x86_64).

Try pre-built AMI first (tagged `Project=always-on-claude`, public, matching architecture), then fall back to stock Ubuntu 24.04:

```bash
# Pre-built (fast path, ~40s)
aws ec2 describe-images --region "$REGION" --filters "Name=tag:Project,Values=always-on-claude" "Name=state,Values=available" "Name=is-public,Values=true" "Name=architecture,Values=${ARCH}" --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' --output text

# Stock Ubuntu fallback (full install, ~90s)
aws ec2 describe-images --owners 099720109477 --region "$REGION" --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${ARCH}-server-*" "Name=state,Values=available" --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' --output text
```

### Step 6E — Launch instance

Use the appropriate user data based on whether a custom AMI or stock Ubuntu was found:

For pre-built AMI:
```bash
#!/bin/bash
exec > /var/log/install.log 2>&1
su - dev -c 'cd ~/dev-env && git pull --ff-only 2>/dev/null && sudo --preserve-env=HOME docker compose up -d'
```

For stock Ubuntu:
```bash
#!/bin/bash
exec > /var/log/install.log 2>&1
su - ubuntu -c "NON_INTERACTIVE=1 bash -c 'curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/scripts/deploy/install.sh | bash'"
```

Launch:
```bash
aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --user-data "$USER_DATA" \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3,DeleteOnTermination=true}' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Project,Value=always-on-claude}]" \
    --query 'Instances[0].InstanceId' --output text
```

Tell the user: "Instance launched — install.sh is running in the background via User Data."

### Step 7E — Wait for instance + SSH

```bash
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
```

Get public IP, then poll SSH (up to 30 attempts, 5s apart):
```bash
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes -i ~/.ssh/$KEY_NAME.pem dev@$IP "echo ok"
```

### Step 8E — Wait for setup to complete

```bash
ssh -o StrictHostKeyChecking=no -o BatchMode=yes -i ~/.ssh/$KEY_NAME.pem dev@$IP "cloud-init status --wait" >/dev/null 2>&1
```

Then poll for the container (up to 60 attempts, 3s apart):
```bash
ssh -o BatchMode=yes -i ~/.ssh/$KEY_NAME.pem dev@$IP "sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q claude-dev"
```

If the container is not running after 3 minutes, show logs:
```bash
ssh -i ~/.ssh/$KEY_NAME.pem dev@$IP "tail -50 /var/log/install.log"
```

### Step 9E — Interactive auth

Tell the user what to expect (git config prompts, GitHub CLI browser auth, Claude Code browser auth), then run:

```bash
ssh -t -i ~/.ssh/$KEY_NAME.pem dev@$IP "sg docker -c 'docker cp ~/dev-env/scripts/deploy/setup-auth.sh claude-dev:/tmp/setup-auth.sh && docker exec -it claude-dev bash /tmp/setup-auth.sh'"
```

### Step 10E — Save workspace info

Write `.env.workspace`:
```bash
cat > .env.workspace << EOF
# Provisioned $(date +%Y-%m-%d)
WORKSPACE_TYPE=ec2
INSTANCE_ID=$INSTANCE_ID
PUBLIC_IP=$IP
REGION=$REGION
INSTANCE_TYPE=$INSTANCE_TYPE
INSTANCE_NAME=$INSTANCE_NAME
SSH_KEY=~/.ssh/$KEY_NAME.pem
SG_ID=$SG_ID
EOF
```

### Step 11E — SSH config

Add (or update) an SSH config entry in `~/.ssh/config` so the user can connect with just `ssh $INSTANCE_NAME`:

- If `Host $INSTANCE_NAME` block exists, update the `HostName` to the new IP
- Otherwise, prepend a new block before any `Host *` wildcard:

```
Host $INSTANCE_NAME
    HostName $IP
    User dev
    IdentityFile ~/.ssh/$KEY_NAME.pem
```

### Step 12E — Shell aliases

Add `cc` and `ccc` aliases to the user's shell config (`~/.zshrc` on macOS, `~/.bashrc` on Linux):

```bash
# Claude Code workspace shortcuts
alias cc="ssh -t $INSTANCE_NAME 'exec bash ~/dev-env/scripts/runtime/start-claude.sh'"
alias ccc="ssh -t $INSTANCE_NAME 'NO_CLAUDE=1 exec bash -l'"
```

If aliases already exist, update them. Tell the user to run `source ~/.zshrc` (or `~/.bashrc`) to activate.

### Step 13E — Optional Tailscale

Ask the user:
```
Would you like to set up Tailscale for private access? (recommended)

  Tailscale provides encrypted SSH access from anywhere on your
  Tailnet, and lets you lock down the public security group.

  You can always set this up later with /tailscale.

Set up Tailscale now? [y/N]:
```

If yes, follow the Tailscale EC2 flow: install on remote, authenticate, set hostname, verify SSH, update SSH config, optionally lock down security group.

If no, skip.

---

## Local Mac Deployment Flow

### Step 3M — Xcode CLI tools

```bash
xcode-select -p 2>&1 || echo "not installed"
```

If not installed, run `xcode-select --install` and tell the user to click Install in the dialog. Wait for them to confirm completion.

### Step 4M — Homebrew

```bash
command -v brew && brew --version || echo "not installed"
```

If not installed:
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### Step 5M — System packages

Install each if missing:
```bash
for pkg in tmux git gh node@22 jq ripgrep fzf; do
    brew list "$pkg" 2>/dev/null || brew install "$pkg"
done
```

Link node@22 if `node` isn't on PATH:
```bash
command -v node || brew link --overwrite node@22
```

### Step 6M — Docker

Check Docker status. If not installed, ask the user to choose Docker Desktop or Colima. If installed but not running, tell them to start it. Verify `docker compose version` works.

### Step 7M — Claude Code

```bash
command -v claude && claude --version || echo "not installed"
```

If not installed: `curl -fsSL https://claude.ai/install.sh | bash`

### Step 8M — Repository + host directories

Clone or update `~/dev-env`:
```bash
if [[ -d ~/dev-env/.git ]]; then
    git -C ~/dev-env pull --ff-only
else
    git clone https://github.com/verkyyi/always-on-claude.git ~/dev-env
fi
```

Create required directories and files:
```bash
mkdir -p ~/.claude/commands ~/.claude/debug ~/.config/gh ~/projects ~/.gitconfig.d ~/.ssh
[[ -f ~/.claude.json ]] || echo '{}' > ~/.claude.json
[[ -f ~/.ssh/known_hosts ]] || touch ~/.ssh/known_hosts
```

Copy statusline, settings, tmux config (same as install-mac.sh).

### Step 9M — Start container

```bash
cd ~/dev-env && docker compose -f docker-compose.yml -f docker-compose.mac.yml pull
cd ~/dev-env && docker compose -f docker-compose.yml -f docker-compose.mac.yml up -d
```

Fix permissions:
```bash
cd ~/dev-env && docker compose -f docker-compose.yml -f docker-compose.mac.yml exec -T -u root dev bash -c "chown -R dev:dev /home/dev/projects /home/dev/.claude" 2>/dev/null || true
```

### Step 10M — Authentication

Tell the user what to expect, then run:
```bash
cd ~/dev-env && docker compose -f docker-compose.yml -f docker-compose.mac.yml exec -it dev bash /home/dev/dev-env/scripts/deploy/setup-auth.sh
```

### Step 11M — Enable SSH (Remote Login)

Check status:
```bash
systemsetup -getremotelogin 2>/dev/null || echo "cannot check"
```

If not enabled, tell the user to enable via System Settings > General > Sharing > Remote Login.

Add AcceptEnv for NO_CLAUDE:
```bash
grep -q 'AcceptEnv NO_CLAUDE' /etc/ssh/sshd_config 2>/dev/null || echo 'AcceptEnv NO_CLAUDE' | sudo tee -a /etc/ssh/sshd_config > /dev/null
```

### Step 12M — Launchd agents (auto-start + auto-update)

```bash
bash ~/dev-env/scripts/deploy/install-updater-mac.sh
bash ~/dev-env/scripts/deploy/autostart-mac.sh
```

### Step 13M — Shell integration

Add to `~/.zprofile` (if not present):
- Homebrew shellenv
- `~/.local/bin` to PATH
- Source `ssh-login.sh`

Add to `~/.zshrc` (if not present):
```bash
alias cc="bash ~/dev-env/scripts/runtime/start-claude.sh"
alias ccc="docker exec -it claude-dev bash -l"
```

### Step 14M — Write workspace info

```bash
cat > ~/dev-env/.env.workspace << EOF
# Provisioned $(date +%Y-%m-%d)
WORKSPACE_TYPE=local-mac
HOSTNAME=$(hostname -s)
DEV_ENV=$HOME/dev-env
EOF
```

Also write the `.env.workspace` in the current repo directory.

### Step 15M — Energy settings

Warn the user:
```
IMPORTANT: For always-on use, configure your Mac to stay awake:
  System Settings > Energy Saver (or Battery > Options)
  - Enable "Prevent automatic sleeping when the display is off"
  - Optionally enable "Wake for network access"
```

### Step 16M — Optional Tailscale

Ask if the user wants Tailscale for private remote access:
- If yes, tell them to run `/tailscale` after this completes
- If no, they can access via local network SSH

---

## Final Summary

### EC2:
```
Deployment complete!

  Instance:  $INSTANCE_ID
  Public IP: $IP
  Region:    $REGION
  Type:      $INSTANCE_TYPE

  Connect:
    cc   — workspace picker (Claude Code + tmux)
    ccc  — host shell
    ssh $INSTANCE_NAME — direct SSH

  Manage:
    /deploy           — re-run setup (idempotent)
    /deploy --from-scratch — destroy and recreate
    /update           — apply pending updates
    /tailscale        — private access via Tailscale
    /destroy          — tear down all resources
```

### Local Mac:
```
Deployment complete!

  Hostname:    $(hostname -s)
  Container:   claude-dev (running)
  Auto-start:  enabled (launchd)
  Auto-update: enabled (every 6 hours)

  From this Mac:
    cc   — workspace picker
    ccc  — container shell

  From other devices:
    ssh USER@HOSTNAME

  Manage:
    /deploy            — re-run setup (idempotent)
    /deploy --from-scratch — destroy and recreate
    /update            — apply pending updates
    /tailscale         — private access via Tailscale
    /destroy-local     — tear down workspace
```

---

## Error handling

- **AWS CLI not configured**: help the user run `aws configure` — do not proceed without valid credentials
- **Instance already exists**: offer to reuse or recreate (requires `--from-scratch`)
- **SSH timeout**: check security group rules, check instance state, show install.log
- **cloud-init errors**: show `/var/log/install.log`
- **Docker pull fails**: install.sh falls back to local build automatically
- **Key pair exists without local file**: help user find it or delete the AWS key pair
- **Docker Desktop not running (Mac)**: guide user to start it, don't retry endlessly
- **Xcode CLI tools dialog (Mac)**: wait for user to complete install
- **SSH not enabled (Mac)**: guide through System Settings, don't try to force-enable

Do NOT blindly retry failed commands. Diagnose and fix, or ask the user.
