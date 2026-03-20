# App Status

You are showing the status of all deployed apps on this workspace.

## Steps

1. Check if any apps are deployed:
```bash
bash ~/dev-env/scripts/runtime/deploy.sh status
```

2. If apps exist, also check Caddy's status:
```bash
docker ps --filter name=caddy --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "Caddy not running"
```

3. For each running app, do a quick health check:
```bash
# For each app's port from the status output
curl -sf -o /dev/null -w "%{http_code}" http://127.0.0.1:<port> 2>/dev/null || echo "unreachable"
```

4. Present a clear summary:

```
Deployed Apps:

  NAME           PORT   TYPE            STATUS    HEALTH   URL
  my-app         3000   nextjs          running   200      https://my-app.<id>.<domain>
  api            4000   dockerfile      running   200      https://api.<id>.<domain>
  blog           5000   static          stopped   -        https://blog.<id>.<domain>

Caddy: running (uptime: 2 days)
```

If no apps are deployed:
```
No apps deployed yet.
Use /deploy in a project directory to deploy your first app.
```
