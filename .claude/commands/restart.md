# Restart App

You are restarting a deployed app.

## Steps

1. First, check which apps are deployed:
```bash
bash ~/dev-env/scripts/runtime/deploy.sh status
```

2. Determine which app to restart:
   - If `$ARGUMENTS` is provided, use it as the app name
   - If only one app is deployed, use that one
   - Otherwise, ask the user which app

3. Restart the app:
```bash
bash ~/dev-env/scripts/runtime/deploy.sh restart <app-name>
```

4. Verify it's back up:
```bash
bash ~/dev-env/scripts/runtime/deploy.sh status
```

5. Show the result:
```
Restarted <app-name>.

  Status: running
  URL:    https://<app-name>.<workspace-id>.<domain>
```

## Error handling

- **App not found**: Show available apps from status
- **Restart fails**: Show container logs to help debug
- **App doesn't come back**: Suggest checking logs with `/logs <app-name>`
