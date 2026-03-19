# Tailscale Setup

## Environment check

First, check if this is a provisioned host:
  test -f ~/dev-env/.provisioned && echo "provisioned" || echo "not provisioned"

If "not provisioned", tell the user:
"This command is only available on a provisioned workspace. SSH into your instance and use [m] to manage workspaces."
Then stop — do not proceed with any further steps.

---

You are setting up Tailscale on a provisioned always-on Claude Code workspace. This enables private SSH access via the user's Tailscale network, removing the need for public SSH exposure.

## Steps

1. **Check current status** — detect whether Tailscale is installed and connected:
   ```bash
   command -v tailscale && echo "installed" || echo "not installed"
   ```
   If installed, check connection:
   ```bash
   tailscale status 2>&1 || true
   ```
   If already installed AND connected, show the current status and Tailscale IP. Tell the user everything is set up and offer to help reconfigure (change hostname, lock down security group). Do not re-run install or auth.

2. **Install** — if `tailscale` is not installed:
   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   ```
   Confirm it installed:
   ```bash
   command -v tailscale && echo "installed" || echo "install failed"
   ```

3. **Authenticate** — if not connected (step 1 showed "Logged out" or failed):
   ```bash
   sudo tailscale up --ssh
   ```
   This prints an auth URL. Tell the user to open it in their browser to authenticate. Wait for them to confirm they've completed authentication, then verify:
   ```bash
   tailscale status
   ```

4. **Set hostname** — ask the user what hostname they'd like for this machine (e.g. `my-dev-server`). Then run:
   ```bash
   sudo tailscale set --hostname <name>
   ```

5. **Verify and guide** — confirm everything is working:
   ```bash
   tailscale status
   tailscale ip -4
   ```
   Then tell the user:
   - Their Tailscale SSH address: `ssh dev@<hostname>` (using the hostname they chose)
   - They should visit https://login.tailscale.com/admin/machines, select their machine, go to SSH, and set access mode to "Accept" (avoids periodic re-authentication prompts)

6. **Suggest security group lockdown** — now that Tailscale SSH works, the user can remove public SSH access. Look up the instance's security group:
   ```bash
   # Get instance ID and security group from instance metadata
   TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
   INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
   REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
   SG_ID=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)
   echo "Instance: $INSTANCE_ID  Region: $REGION  Security Group: $SG_ID"
   ```
   Show the user the command to revoke public SSH and ask if they'd like to run it:
   ```bash
   aws ec2 revoke-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 --region "$REGION"
   ```
   **Important:** Warn the user that this removes ALL public SSH access. They should verify Tailscale SSH works first (`ssh dev@<hostname>` from another machine on their tailnet) before revoking. If they get locked out, they'll need to re-add the rule via the AWS console.

## Important

- This runs on the **host**, not inside the container
- Each step checks before acting — never re-install or re-authenticate if already done
- Always verify Tailscale SSH works before suggesting security group changes
- The user must have an existing Tailscale account — we don't create one for them
