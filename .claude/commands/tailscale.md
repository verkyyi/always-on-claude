# Tailscale Setup

You are setting up Tailscale on a provisioned always-on Claude Code workspace. This enables private SSH access via Tailscale, removing the need for public SSH exposure.

## Environment check

First, load the workspace info:
```bash
cat .env.workspace 2>/dev/null || echo "NOT FOUND"
```

If `.env.workspace` is missing, tell the user:
"No workspace found. Run `/provision` or `/provision-local` first to create a workspace."
Then stop.

Source the file to get `WORKSPACE_TYPE` and other variables.

---

**Branch on `WORKSPACE_TYPE`:**
- `local-mac` → follow the **Local Mac** flow below
- `ec2` (or unset) → follow the **EC2** flow below

---

# Local Mac flow

## Step 1 — Check current status

Check if Tailscale is installed locally:
```bash
command -v tailscale && tailscale status 2>&1 || echo "not installed"
```

If already installed AND connected, show the status and skip to Step 4 (verify).

---

## Step 2 — Install Tailscale

```bash
brew install --cask tailscale
```

Tell the user to open the Tailscale app from Applications to complete initial setup.

---

## Step 3 — Authenticate

```bash
tailscale up --ssh
```

This will open a browser for auth. Wait for the user to confirm, then verify:
```bash
tailscale status
```

Ask the user what hostname they'd like (suggest `$(hostname -s)` as default):
```bash
sudo tailscale set --hostname <name>
```

---

## Step 4 — Verify Tailscale SSH works

Test from another device on the Tailnet, or verify the node appears:
```bash
tailscale status
```

Tell the user to visit https://login.tailscale.com/admin/machines, select their machine, go to SSH, and set access mode to "Accept" (avoids periodic re-auth prompts).

---

## Step 5 — Summary

```
Tailscale setup complete!

  Hostname:  <hostname>
  Connect:   ssh USER@<hostname>  (from any device on your Tailnet)

  Your Mac is now accessible from anywhere via Tailscale.
  No security group changes needed (no AWS resources).
```

---

# EC2 flow

This runs from the user's **local Mac**. Source `.env.workspace` to get `INSTANCE_ID`, `PUBLIC_IP`, `SSH_KEY`, `SG_ID`, `REGION`, `INSTANCE_NAME`.

## Step 1 — Check current status

SSH into the remote and check if Tailscale is installed and connected:
```bash
ssh -i $SSH_KEY ubuntu@$PUBLIC_IP "command -v tailscale && sudo tailscale status 2>&1 || echo 'not installed'"
```

If already installed AND connected, show the status and skip to Step 5 (verify + lockdown).

---

## Step 2 — Install Tailscale on remote

If not installed, SSH in and install:
```bash
ssh -i $SSH_KEY ubuntu@$PUBLIC_IP "curl -fsSL https://tailscale.com/install.sh | sh"
```

Verify:
```bash
ssh -i $SSH_KEY ubuntu@$PUBLIC_IP "command -v tailscale && echo 'installed' || echo 'install failed'"
```

---

## Step 3 — Authenticate

Run `tailscale up --ssh` on the remote. This will print an auth URL:
```bash
ssh -t -i $SSH_KEY ubuntu@$PUBLIC_IP "sudo tailscale up --ssh"
```

Tell the user to open the URL in their browser to authenticate. Wait for them to confirm, then verify:
```bash
ssh -i $SSH_KEY ubuntu@$PUBLIC_IP "sudo tailscale status"
```

---

## Step 4 — Set hostname

Ask the user what hostname they'd like (suggest the current `INSTANCE_NAME` as default). Then:
```bash
ssh -i $SSH_KEY ubuntu@$PUBLIC_IP "sudo tailscale set --hostname <name>"
```

---

## Step 5 — Verify Tailscale SSH works

Test SSH via Tailscale hostname from the local machine:
```bash
ssh -o ConnectTimeout=5 ubuntu@<hostname> "echo connected"
```

If this fails, do NOT proceed to lockdown. Troubleshoot first.

Tell the user to visit https://login.tailscale.com/admin/machines, select their machine, go to SSH, and set access mode to "Accept" (avoids periodic re-auth prompts).

---

## Step 6 — Update local SSH config and shell aliases

Update the existing `Host $INSTANCE_NAME` block in `~/.ssh/config`:
- Change `HostName` to the Tailscale hostname
- Remove `IdentityFile` (Tailscale handles auth)

Show the user the before/after and confirm before editing.

Update the `ccc` alias in the user's shell config (`~/.zshrc` on macOS, `~/.bashrc` on Linux). Tailscale SSH doesn't support OpenSSH's `AcceptEnv`/`SetEnv`, so env vars must be passed via the remote command:
```bash
alias ccc="ssh -t $INSTANCE_NAME 'NO_CLAUDE=1 exec bash -l'"
```

If the alias already uses `SetEnv`, replace it. Tell the user to run `source ~/.zshrc` to activate.

---

## Step 7 — Lock down security group

Now that Tailscale SSH works, revoke public SSH access:
```bash
aws ec2 revoke-security-group-ingress --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $REGION
```

**Warn the user** before running: this removes ALL public SSH access. If Tailscale goes down, they'll need to re-add the rule via AWS console.

Verify the public IP is blocked:
```bash
ssh -o ConnectTimeout=5 -i $SSH_KEY ubuntu@$PUBLIC_IP "echo test" 2>&1 || echo "blocked (expected)"
```

---

## Step 8 — Summary

```
Tailscale setup complete!

  Hostname:  <hostname>
  Connect:   ssh $INSTANCE_NAME

  Security group $SG_ID: public SSH revoked
  To restore public access if needed:
    aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 22 --cidr YOUR_IP/32 --region $REGION
```

---

## Important

- For EC2: all remote commands are executed via SSH using credentials from `.env.workspace`
- For local Mac: Tailscale runs directly on the Mac, no SSH needed for setup
- Always verify Tailscale SSH works before locking down (EC2 only)
- The user must have an existing Tailscale account
