# Revoke Temporary Access

You are helping the user revoke temporary SSH access grants from their workspace.

## Environment check

First, check if this is a provisioned host:
```bash
test -f ~/dev-env/.provisioned && echo "provisioned" || echo "not provisioned"
```

If "not provisioned", tell the user:
"This command is only available on a provisioned workspace. SSH into your instance first."
Then stop.

---

## Steps

1. Show current temporary access grants:
   ```bash
   bash ~/dev-env/scripts/runtime/share.sh list
   ```

2. If no grants exist, tell the user and stop.

3. If grants exist, ask the user:
   - **Revoke all** — remove every temporary access grant
   - **Revoke specific** — remove a specific grant by ID

4. Run the appropriate command:
   ```bash
   bash ~/dev-env/scripts/runtime/share.sh revoke all
   ```
   or:
   ```bash
   bash ~/dev-env/scripts/runtime/share.sh revoke <id>
   ```

5. Also clean up any expired grants:
   ```bash
   bash ~/dev-env/scripts/runtime/share.sh cleanup
   ```

6. Confirm the result:
   ```bash
   bash ~/dev-env/scripts/runtime/share.sh list
   ```

Tell the user that any guests using revoked keys will be disconnected on their next connection attempt (active SSH sessions are not terminated).

---

## Important

- This runs on the **host**, not inside the container
- Revoking a key does NOT kill active SSH sessions — it only prevents new connections
- To forcibly disconnect a guest, the user would need to kill their SSH process manually
