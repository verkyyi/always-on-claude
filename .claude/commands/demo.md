You are managing a demo server for always-on-claude. This command creates temporary demo accounts so potential users can try the workspace workflow before setting up their own.

## Context

- Running as: !`whoami`
- Container status: !`docker ps --format '{{.Names}}' 2>/dev/null | grep claude-dev || echo "NOT RUNNING"`
- Demo server configured: !`cat .env.demo 2>/dev/null || echo "NOT CONFIGURED — run install-demo.sh first"`
- Active demo users: !`grep '^demo-' /etc/passwd 2>/dev/null | cut -d: -f1 | while read u; do exp=$(cat /home/$u/.demo-expires 2>/dev/null || echo "no expiry"); echo "  $u (expires: $exp)"; done; grep -c '^demo-' /etc/passwd 2>/dev/null | xargs -I{} echo "  Total: {} demo users" || echo "  none"`

---

## Before you start

If the demo server is NOT CONFIGURED, tell the user to run:
```bash
sudo bash scripts/demo/install-demo.sh
```

If the container is NOT RUNNING, help start it first.

---

## Actions

Based on `$ARGUMENTS`, do one of:

### "create" (default if no arguments)

Create a new demo account:

```bash
sudo bash scripts/demo/create-demo.sh
```

Or with a custom TTL:
```bash
sudo DEMO_TTL=3600 bash scripts/demo/create-demo.sh
```

After creation, show the user:
1. The SSH connection command
2. The private key (they need to save it to a file)
3. Reminder that the demo user needs to run `claude login` with their own subscription

### "list"

Show all active demo users with their expiry times.

### "cleanup"

Manually trigger cleanup of expired users:

```bash
sudo bash scripts/demo/cleanup-demo.sh
```

### "setup"

First-time setup of the demo server:

```bash
sudo bash scripts/demo/install-demo.sh
```

---

## Error handling

- **Not root**: demo scripts need sudo — run them with sudo
- **Container not running**: start it first with `docker compose up -d`
- **No demo-server marker**: run install-demo.sh to configure the host
