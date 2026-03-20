# App Logs

You are showing logs for a deployed app.

## Steps

1. First, check which apps are deployed:
```bash
bash ~/dev-env/scripts/runtime/deploy.sh status
```

2. Determine which app to show logs for:
   - If `$ARGUMENTS` is provided, use it as the app name
   - If only one app is deployed, use that one
   - Otherwise, ask the user which app

3. Show the logs:
```bash
bash ~/dev-env/scripts/runtime/deploy.sh logs <app-name> 100
```

4. Ask the user if they want to see more lines or follow the logs:
   - More lines: `bash ~/dev-env/scripts/runtime/deploy.sh logs <app-name> 500`
   - Follow (live): `docker logs -f app-<app-name>` (warn this will block the session)

## Error handling

- **App not found**: Show available apps from status
- **No logs**: The container may have just started — suggest waiting a moment
