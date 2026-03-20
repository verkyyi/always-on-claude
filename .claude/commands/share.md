# Temporary Access Sharing

You are helping the user share temporary SSH access to their workspace. This is for lightweight collaboration — "show a friend your side project," not team access control.

## Environment check

First, check if this is a provisioned host:
```bash
test -f ~/dev-env/.provisioned && echo "provisioned" || echo "not provisioned"
```

If "not provisioned", tell the user:
"This command is only available on a provisioned workspace. SSH into your instance first."
Then stop.

---

## What to do

Ask the user what they'd like:

### 1. Create a temporary access grant

Ask how long the access should last (default: 24 hours). Then run:
```bash
bash ~/dev-env/scripts/runtime/share.sh create <hours>
```

The script will:
- Generate a temporary Ed25519 SSH key pair
- Add the public key to `~/.ssh/authorized_keys` with expiry metadata and restrictions
- Output the private key and connection instructions for the guest

Share the full output with the user. Remind them:
- The guest gets a restricted shell (no port forwarding, no agent forwarding)
- The key expires automatically — but run `/unshare` to revoke early if needed
- The guest connects to the same user account, so they can see all projects

### 2. List active access grants

```bash
bash ~/dev-env/scripts/runtime/share.sh list
```

Show the results. Highlight any expired grants and suggest running cleanup.

### 3. Revoke access

Ask whether to revoke a specific grant (by ID) or all grants:
```bash
bash ~/dev-env/scripts/runtime/share.sh revoke <id>
bash ~/dev-env/scripts/runtime/share.sh revoke all
```

### 4. Clean up expired keys

```bash
bash ~/dev-env/scripts/runtime/share.sh cleanup
```

This removes expired keys from `authorized_keys`. Safe to run anytime.

---

## Important

- This runs on the **host**, not inside the container
- Temporary keys are marked with `# TEMP_ACCESS` comments in `authorized_keys`
- The `restrict,pty` option limits the guest: no port forwarding, no agent forwarding, no X11 — but they get an interactive shell
- Guests share the same user account — they can see files, but this is for trusted sharing only
- Suggest setting up a cron job for automatic cleanup: `0 * * * * bash ~/dev-env/scripts/runtime/share.sh cleanup`
