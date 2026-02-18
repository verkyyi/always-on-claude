# Always-On Claude Code: EC2 + Docker Compose

A reproducible, always-on development environment on AWS for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) autonomously — including overnight unattended workflows.

**~$22/mo.** No ports exposed. Connect from anywhere — laptop, phone, tablet.

---

## Why This Setup?

Running Claude Code locally ties you to your laptop. This setup gives you a persistent cloud dev environment you can connect to from anywhere and leave Claude working overnight while you sleep. It's cheap, secure (Tailscale mesh VPN, no open ports), and reproducible (Docker).

---

## Architecture

```
Your Laptop / Phone (Terminus, VS Code, etc.)
    │
    ├── Tailscale VPN (encrypted mesh)
    │
    └── EC2 Instance (t3.medium)
         ├── Docker Compose
         │    └── Dev Container
         │         ├── Claude Code (native installer)
         │         ├── Node.js 22 + npm
         │         ├── AWS CLI v2
         │         ├── Git + GitHub CLI
         │         ├── ripgrep, fzf, zsh
         │         └── Your project repo
         ├── tmux (session persistence)
         └── 30GB gp3 EBS (persistent storage)
```

---

## Files in This Repo

| File | Purpose |
|------|---------|
| [`Dockerfile.dev`](Dockerfile.dev) | Ubuntu 24.04, Node 22, AWS CLI, gh, Claude Code (native), ripgrep/fzf/zsh |
| [`docker-compose.yml`](docker-compose.yml) | Persistent volumes, host networking for IAM role |
| [`cloudformation.yml`](cloudformation.yml) | EC2 + security group + IAM role stack |
| [`bootstrap.sh`](bootstrap.sh) | One-shot EC2 setup (Docker, tmux, Tailscale) |
| [`load-secrets.sh`](load-secrets.sh) | Pulls secrets from AWS SSM Parameter Store into env vars |
| [`overnight-tasks.sh`](overnight-tasks.sh) | Autonomous Claude Code task runner |
| [`start-claude.sh`](start-claude.sh) | Starts container if needed, launches Claude Code in tmux |
| [`ssh-login.sh`](ssh-login.sh) | Interactive SSH login menu — Claude Code or plain shell |
| [`git-check.sh`](git-check.sh) | Daily repo health check — git status, linting, tests, docs, auto-fix, GitHub issues |
| [`git-check.cron`](git-check.cron) | Cron schedule for `git-check.sh` (runs daily at 08:00) |

---

## Quick Start

### 1. Deploy the EC2 instance

```bash
aws cloudformation create-stack \
  --stack-name my-dev \
  --template-body file://cloudformation.yml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=KeyPairName,ParameterValue=your-key \
    ParameterKey=MyIP,ParameterValue=$(curl -s ifconfig.me)/32
```

### 2. Bootstrap the server

```bash
scp -i your-key.pem bootstrap.sh ubuntu@<PUBLIC_IP>:~/
ssh -i your-key.pem ubuntu@<PUBLIC_IP> 'bash ~/bootstrap.sh'
```

### 3. Set up Tailscale

```bash
# On the EC2 instance
sudo tailscale up --ssh
sudo tailscale set --hostname my-dev-server

# Then lock down the security group — remove public SSH
aws ec2 revoke-security-group-ingress \
  --group-id sg-YOUR_SG_ID \
  --protocol tcp --port 22 --cidr YOUR_IP/32
```

> **Tailscale SSH access mode:** After enabling `--ssh`, go to the [Tailscale admin console](https://login.tailscale.com/admin/machines) → select your machine → SSH → set access mode to **Accept** (not the default **Check**). Check mode requires periodic re-authentication and can interrupt normal SSH sessions. Accept mode lets SSH work transparently.

Install [Tailscale](https://tailscale.com/download) on your laptop/phone and join the same network. Now you connect with just:

```bash
ssh ubuntu@my-dev-server
```

### 4. Upload files and start the container

```bash
scp -r ./* ubuntu@my-dev-server:~/dev-env/
ssh ubuntu@my-dev-server

# Pre-create bind mount targets (must exist before first docker compose up)
mkdir -p ~/.claude
touch ~/.claude.json

cd ~/dev-env
docker compose up -d

# Fix named volume permissions (Docker volumes mount as root)
docker compose exec -u root dev bash -c \
  "chown -R dev:dev /home/dev/project"
```

### 5. One-time setup inside the container

```bash
docker compose exec dev bash

# Git config
git config --global user.name "Your Name"
git config --global user.email "you@example.com"

# Clone your project (use HTTPS — .ssh mount is read-only)
cd ~/project
git clone https://github.com/your-org/your-repo.git .
npm install

# Auth
gh auth login
claude login    # subscription auth, not API key — see gotchas below

# Verify
aws sts get-caller-identity
claude -p "hello"
```

---

## One-Command Access

After bootstrap, every SSH login shows an interactive menu:

```
  ┌─────────────────────────────┐
  │  [1] Claude Code (3s)       │
  │  [2] Plain shell            │
  └─────────────────────────────┘
```

Wait 3 seconds (or press Enter) and you're in Claude Code — container auto-starts if needed, tmux session auto-resumes if one exists. Press `2` for a normal shell.

This works from **any SSH client on any device** — no client-side config required. Phone, tablet, someone else's laptop — just `ssh ubuntu@my-dev-server`.

If an existing tmux session is running (e.g. from an overnight task), you'll reattach to it and see exactly where things left off.

**Bypass the menu entirely:**

```bash
# Force plain shell (e.g. in scripts or automation)
ssh dev-server -t "NO_CLAUDE=1 bash"
```

---

## Overnight Autonomous Workflows

This is the real payoff. Define tasks, SSH in (option 1), detach, and go to sleep.

```bash
ssh ubuntu@my-dev-server
# → auto-enters Claude Code via menu

# Or start the overnight script directly:
# Press 2 for shell, then:
docker compose exec dev bash
tmux new -s overnight
cd ~/project
bash ~/dev-env/overnight-tasks.sh

# Detach: Ctrl+A, then D
# Close your laptop. Sleep.
```

Edit [`overnight-tasks.sh`](overnight-tasks.sh) to define your tasks before each run. Each task gets a 10-minute timeout, and the script produces a Markdown log with git diffs and test results.

Next morning — just SSH in. The menu will reattach to your running tmux session automatically.

```bash
ssh ubuntu@my-dev-server
# → reattaches to existing Claude Code session

# Or just pull from your laptop
git pull origin main
```

---

## Daily Repository Health Check

`git-check.sh` runs automatically every morning at 08:00 via cron. For each git repo found under `$HOME` it:

1. **Git health** — flags uncommitted changes, unpushed commits, and stale branches (>30 days)
2. **Code quality** — runs linters and formatters via Claude
3. **Test coverage** — runs the test suite and flags untested files via Claude
4. **Documentation** — checks README, docstrings, and public API docs via Claude
5. **Auto-fix** — applies safe formatter/linter fixes and commits them locally via Claude
6. **GitHub issues** — files issues for significant problems found via Claude

Output appends to `~/git-check.log`.

### Activate the cron job

```bash
sudo cp ~/dev-env/git-check.cron /etc/cron.d/git-daily-check
```

### Run manually

```bash
# Full run (git checks + Claude analysis)
bash ~/dev-env/git-check.sh

# Git checks only — no Claude
SKIP_ANALYSIS=1 bash ~/dev-env/git-check.sh

# Custom log location
LOG=/tmp/mylog.log bash ~/dev-env/git-check.sh
```

---

## Secrets Management

Use AWS SSM Parameter Store instead of `.env` files with raw secrets:

```bash
# Store (from your laptop)
aws ssm put-parameter --name "/myproject/api-key" --value "secret" --type SecureString

# Retrieve (inside the container — uses EC2 instance role)
aws ssm get-parameter --name "/myproject/api-key" --with-decryption --query 'Parameter.Value' --output text
```

Edit [`load-secrets.sh`](load-secrets.sh) with your parameter names. The overnight script sources it automatically.

---

## Multi-User Setup

**Shared container, separate tmux sessions:**

```bash
ssh ubuntu@my-dev-server
docker compose exec dev bash
tmux new -s teammate-session
git checkout -b feature/their-work
claude
```

**Full isolation — add a second service to `docker-compose.yml`:**

```yaml
  dev-teammate:
    build:
      context: .
      dockerfile: Dockerfile.dev
    container_name: dev-teammate
    volumes:
      - claude-data-teammate:/home/dev/.claude
      - project-data-teammate:/home/dev/project
      - ~/.ssh:/home/dev/.ssh:ro
    environment:
      - AWS_DEFAULT_REGION=us-east-1
    network_mode: host
    restart: unless-stopped
```

Each user runs `claude login` inside their own container.

---

## Gotchas and Lessons Learned

These are real issues hit during setup — none documented anywhere obvious.

1. **Claude Code requires `ripgrep`, `fzf`, and `zsh`.** Without them it exits silently with "Execution error" and no useful message. The Dockerfile includes all three.

2. **Claude Code needs `~/.claude/debug/` and `~/.claude/remote-settings.json`.** If missing, it crashes with `ENOENT` errors. The Dockerfile pre-creates them, but Docker volumes mount as root and can overwrite ownership. Always fix permissions after first `docker compose up`:
   ```bash
   docker compose exec -u root dev bash -c \
     "chown -R dev:dev /home/dev/project"
   ```

3. **Claude Code stores onboarding state in `~/.claude.json` (NOT inside `~/.claude/`).** This is a separate file in the home directory root. If you only bind-mount `~/.claude/`, this file lives in the container's ephemeral filesystem and gets wiped on every `docker compose down && up` — causing Claude Code to re-run the full setup (theme, trust prompt, onboarding) every time. Fix: bind-mount `~/.claude.json` separately. Run `touch ~/.claude.json` on the host before first start, or Docker will create it as a directory.

4. **Use `docker compose stop/start`, not `down/up` for daily work.** `stop`/`start` preserves the container and all its state. `down` destroys and recreates the container. Only use `down`/`up` when you've changed the Dockerfile or docker-compose.yml. With the bind mounts above, `down`/`up` should also work — but `stop`/`start` is safer and faster.

5. **Set `hostname` in docker-compose.yml.** Without a fixed hostname, each new container gets a random one. Claude Code may tie OAuth tokens to the hostname, causing re-auth after `down`/`up`.

6. **Use subscription auth (`claude login`), not `ANTHROPIC_API_KEY`.** Setting the env var overrides your subscription and uses API credits instead. The docker-compose.yml intentionally does *not* set `ANTHROPIC_API_KEY`. Run `claude login` once inside the container — the OAuth token persists in the bind-mounted `~/.claude/` directory.

7. **Clone via HTTPS, not SSH.** The `~/.ssh` volume is mounted read-only, so git can't write to `known_hosts`. Use `git clone https://...` and authenticate via `gh auth login`.

8. **Tailscale CLI on macOS isn't in PATH.** Use the full path:
   ```bash
   /Applications/Tailscale.app/Contents/MacOS/Tailscale status
   ```

9. **`docker-compose.yml` `version` key is obsolete.** Docker Compose v2 ignores it and prints a warning. Just omit it.

10. **CloudFormation security group descriptions must be ASCII.** Em dashes and other non-ASCII characters cause `CREATE_FAILED`.

---

## Cost

| Item | Monthly |
|------|---------|
| EC2 t3.medium (on-demand) | ~$30 |
| EC2 t3.medium (1yr reserved) | ~$19 |
| EBS 30GB gp3 | ~$2.40 |
| Tailscale | Free |
| Data transfer | ~$1–2 |
| **Total** | **~$22–34** |

> Spot Instances can bring EC2 down to ~$9–10/mo. You'll need to handle occasional interruptions.

---

## Maintenance

```bash
# Update Claude Code
docker compose exec dev bash -c "curl -fsSL https://claude.ai/install.sh | bash"

# Rebuild container
docker compose build && docker compose up -d

# Backup project data
docker run --rm -v dev-env_project-data:/data -v ~/backups:/backup \
  ubuntu tar czf /backup/project-$(date +%Y%m%d).tar.gz -C /data .
```

---

## Quick Reference

| Action | Command |
|--------|---------|
| SSH → Claude Code | `ssh ubuntu@my-dev-server` (wait 3s or press Enter) |
| SSH → plain shell | `ssh ubuntu@my-dev-server` then press `2` |
| SSH → plain shell (scripted) | `ssh dev-server -t "NO_CLAUDE=1 bash"` |
| Enter container manually | `docker compose exec dev bash` |
| New tmux session | `tmux new -s work` |
| Detach tmux | `Ctrl+A`, then `D` |
| Reattach tmux | `tmux attach -t work` |
| Claude autonomous | `claude -p "task" --dangerously-skip-permissions` |
| Overnight script | `bash ~/dev-env/overnight-tasks.sh` |
| Daily health check | `bash ~/dev-env/git-check.sh` |
| Health check (git only) | `SKIP_ANALYSIS=1 bash ~/dev-env/git-check.sh` |
| View health check log | `tail -f ~/git-check.log` |
| Fix permissions | `docker compose exec -u root dev bash -c "chown -R dev:dev /home/dev/.claude /home/dev/project"` |
| Re-auth Claude | `claude login` |

---

## License

MIT
