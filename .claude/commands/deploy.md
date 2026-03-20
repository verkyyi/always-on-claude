# Deploy App

You are deploying a web app from the current project to this workspace's auto-DNS subdomain with HTTPS.

## Environment check

First, verify deployment is configured:
```bash
source ~/dev-env/.env.workspace 2>/dev/null || true
echo "WORKSPACE_ID=${WORKSPACE_ID:-NOT SET}"
echo "WORKSPACE_DOMAIN=${WORKSPACE_DOMAIN:-NOT SET}"
echo "WORKSPACE_TYPE=${WORKSPACE_TYPE:-ec2}"
```

If `WORKSPACE_ID` or `WORKSPACE_DOMAIN` is `NOT SET`, tell the user:
"App deployment is not configured on this workspace. The provisioning process needs to set WORKSPACE_ID and WORKSPACE_DOMAIN in .env.workspace."
Then stop.

---

## Step 1 — Detect project

Check what's in the current directory:
```bash
ls -la
```

Auto-detect the project type:
```bash
bash ~/dev-env/scripts/runtime/deploy.sh deploy . 2>&1 | head -5
```

Wait — don't run the deploy yet. First show the user what was detected and ask for confirmation:

```
I detected:
  Project:  <directory name>
  Type:     <docker-compose | dockerfile | nextjs | node | python | static>
  Path:     <absolute path>

App name? (default: <dirname>)
```

If `$ARGUMENTS` is provided, use it as the app name. Otherwise ask.

---

## Step 2 — Deploy

Run the deployment:
```bash
bash ~/dev-env/scripts/runtime/deploy.sh deploy <project-dir> <app-name>
```

Show the full output to the user.

---

## Step 3 — Verify

Check that the app is responding:
```bash
bash ~/dev-env/scripts/runtime/deploy.sh status
```

---

## Step 4 — Summary

```
Deployed!

  URL:   https://<app-name>.<workspace-id>.<domain>
  Port:  <port>
  Type:  <type>

  Commands:
    /app-status   — check all deployed apps
    /logs         — view app logs
    /restart      — restart the app
```

---

## Error handling

- **Port conflict**: The script auto-assigns the next available port
- **Build failure**: Show full build output, help debug
- **Caddy not running**: The script auto-starts it via the deploy profile
- **Health check fails**: Warn but don't fail — the app may need more startup time
