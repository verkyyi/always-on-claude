# Always-On Claude Code

A reproducible, always-on development environment for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) autonomously — including overnight unattended workflows.

**~$22/mo on AWS.** No ports exposed. Connect from anywhere — laptop, phone, tablet. Works on any Ubuntu 24.04 server.

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
    └── Ubuntu 24.04 Server (any provider)
         ├── Docker Compose
         │    └── Dev Container
         │         ├── Claude Code (native installer)
         │         ├── Node.js 22 + npm
         │         ├── AWS CLI v2
         │         ├── Git + GitHub CLI
         │         ├── ripgrep, fzf, zsh
         │         └── Your project repo
         ├── tmux (session persistence)
         └── 30GB+ storage
```

---

## Files in This Repo

| File | Purpose |
|------|---------|
| [`provision.sh`](provision.sh) | **Run from your laptop** — provisions AWS EC2 + runs install.sh over SSH |
| [`install.sh`](install.sh) | **Run on the server** — automates full setup, guides through auth |
| [`setup-auth.sh`](setup-auth.sh) | In-container auth helper (git, gh, claude login) |
| [`Dockerfile.dev`](Dockerfile.dev) | Ubuntu 24.04, Node 22, AWS CLI, gh, Claude Code (native), ripgrep/fzf/zsh |
| [`docker-compose.yml`](docker-compose.yml) | Persistent volumes, host networking for IAM role |
| [`cloudformation.yml`](cloudformation.yml) | EC2 + security group + IAM role stack |
| [`bootstrap.sh`](bootstrap.sh) | Legacy one-shot setup (deprecated — use `install.sh`) |
| [`load-secrets.sh`](load-secrets.sh) | Pulls secrets from AWS SSM Parameter Store into env vars |
| [`overnight-tasks.sh`](overnight-tasks.sh) | Simple autonomous task runner — hardcode tasks directly in the script |
| [`run-tasks.sh`](run-tasks.sh) | Task runner that reads `tasks.txt` from `~/overnight/` — use with `/plan-overnight` |
| [`trigger-watcher.sh`](trigger-watcher.sh) | Host-side cron watcher — detects `.scheduled` sidecars and queues `docker exec` jobs via `at` |
| [`start-claude.sh`](start-claude.sh) | Starts container if needed, launches Claude Code in tmux |
| [`ssh-login.sh`](ssh-login.sh) | Interactive SSH login menu — Claude Code or plain shell |
| [`git-check.sh`](git-check.sh) | Daily repo health check — git status, linting, tests, docs, auto-fix, GitHub issues |
| [`git-check.cron`](git-check.cron) | Cron schedule for `git-check.sh` (runs daily at 08:00) |
| [`commands/plan-overnight.md`](commands/plan-overnight.md) | Claude Code slash command — deploy to `~/.claude/commands/` |

---

## Prerequisites

You need these accounts/tools before starting:

| What | Why | From scratch |
|------|-----|--------------|
| **Cloud server or AWS account** | Hosts the environment | ~10 min (AWS signup) or already have a VPS |
| **AWS CLI** *(AWS path only)* | `provision.sh` talks to AWS | ~5 min (`brew install awscli` + `aws configure`) |
| **[Tailscale](https://tailscale.com/) account** | Secure SSH from anywhere, no open ports | ~2 min (free) |
| **GitHub account** | Push/pull repos via `gh auth` | You probably have this |
| **Claude Max or Team subscription** | `claude login` inside the container | You probably have this |

Already have AWS + GitHub + Claude? You just need a [Tailscale account](https://login.tailscale.com/start) (free, 2 minutes).

---

## How Long Does It Take?

**First run (AWS path, from laptop to working Claude Code): ~10-15 minutes.**

```
provision.sh (your laptop)
├── Preflight + key pair + AMI lookup       ~10s
├── CloudFormation create + wait            ~2-3 min     ← server booting
├── Wait for SSH ready                      ~30-60s
│
install.sh Phase 1 (on server, automated)
├── System packages (Docker, tmux, at)      ~1-2 min
├── Tailscale binary install                ~15s
├── Git clone repo                          ~5s
├── Create host dirs + files                ~1s
├── docker compose build                    ~3-5 min     ← biggest step
└── docker compose up + fix permissions     ~10s
│
install.sh Phase 2 (interactive, needs browser)
├── Tailscale auth — paste URL, approve     ~1-2 min
├── Git config — type name + email          ~30s
├── gh auth login — paste device code       ~1 min
└── claude login — paste URL                ~1 min
```

**Re-run (idempotent):** ~30 seconds — everything skips.

---

## Quick Start

You need an Ubuntu 24.04 server with at least 2 vCPUs, 4 GB RAM, and 30 GB storage. Pick whichever path gets you there:

### Option A: I already have a server

If you have any Ubuntu 24.04 VPS (DigitalOcean, Hetzner, Linode, Vultr, your own hardware, etc.):

```bash
ssh root@<YOUR_SERVER_IP>
curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/install.sh | bash
```

That's it. The script installs everything, then walks you through Tailscale, git, GitHub, and Claude auth.

### Option B: I need a server (AWS, fully automated)

One command from your laptop. Provisions an EC2 instance and bootstraps it over SSH:

```bash
curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/provision.sh | bash
```

**Prerequisites:** AWS CLI installed and configured (`aws configure`). The script handles everything else — key pair, AMI lookup, CloudFormation stack, waiting for boot, SSH, and running `install.sh`.

Override defaults with env vars:
```bash
STACK_NAME=my-dev KEY_NAME=my-key AWS_REGION=us-west-2 bash provision.sh
```

<details>
<summary>New to AWS? Step-by-step setup</summary>

1. **Create an AWS account** at [aws.amazon.com](https://aws.amazon.com/). New accounts get 12 months of free tier (t3.medium is not free tier, but costs ~$30/mo).

2. **Install the AWS CLI:**
   - macOS: `brew install awscli`
   - Linux: `sudo apt install awscli` or [official installer](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
   - Windows: [MSI installer](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)

3. **Create an access key:** Go to [IAM console](https://console.aws.amazon.com/iam/) → Users → your user → Security credentials → Create access key

4. **Configure the CLI:**
   ```bash
   aws configure
   # Enter your access key, secret key, and preferred region (e.g. us-east-1)
   ```

5. **Run the provisioning script:**
   ```bash
   curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/provision.sh | bash
   ```

</details>

### Option C: I need a server (other providers)

Any Ubuntu 24.04 VPS works. Here's how to get one:

<details>
<summary>DigitalOcean (~$24/mo)</summary>

1. Sign up at [digitalocean.com](https://www.digitalocean.com/)
2. Create a Droplet: **Ubuntu 24.04**, **Regular $24/mo** (2 vCPU, 4 GB, 80 GB), choose a region
3. Add your SSH key (or use their console password)
4. Once created, copy the IP address and run:
   ```bash
   ssh root@<DROPLET_IP>
   curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/install.sh | bash
   ```

</details>

<details>
<summary>Hetzner (~EUR 4.5/mo)</summary>

1. Sign up at [hetzner.com](https://www.hetzner.com/cloud/)
2. Create a server: **Ubuntu 24.04**, **CX22** (2 vCPU, 4 GB, 40 GB), choose a location
3. Add your SSH key
4. Once created, copy the IP address and run:
   ```bash
   ssh root@<SERVER_IP>
   curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/install.sh | bash
   ```

</details>

<details>
<summary>Linode/Akamai (~$24/mo)</summary>

1. Sign up at [linode.com](https://www.linode.com/)
2. Create a Linode: **Ubuntu 24.04**, **Linode 4GB** (2 vCPU, 4 GB, 80 GB), choose a region
3. Set a root password or add your SSH key
4. Once created, copy the IP address and run:
   ```bash
   ssh root@<LINODE_IP>
   curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/install.sh | bash
   ```

</details>

### After setup

Install [Tailscale](https://tailscale.com/download) on your laptop/phone and join the same network. Now you connect with just:

```bash
ssh ubuntu@my-dev-server
```

> **Tailscale SSH access mode:** After enabling `--ssh`, go to the [Tailscale admin console](https://login.tailscale.com/admin/machines) → select your machine → SSH → set access mode to **Accept** (not the default **Check**). Check mode requires periodic re-authentication and can interrupt normal SSH sessions. Accept mode lets SSH work transparently.

<details>
<summary><strong>Manual Setup (Reference)</strong></summary>

If you prefer to run each step manually instead of using `install.sh`:

#### Bootstrap the server

```bash
scp -i your-key.pem bootstrap.sh ubuntu@<PUBLIC_IP>:~/
ssh -i your-key.pem ubuntu@<PUBLIC_IP> 'bash ~/bootstrap.sh'
```

#### Set up Tailscale

```bash
sudo tailscale up --ssh
sudo tailscale set --hostname my-dev-server
```

#### Upload files and start the container

```bash
scp -r ./* ubuntu@my-dev-server:~/dev-env/

# Deploy slash commands
mkdir -p ~/.claude/commands
cp ~/dev-env/commands/plan-overnight.md ~/.claude/commands/

# Pre-create bind mount targets
mkdir -p ~/.claude/debug
touch ~/.claude.json
mkdir -p ~/overnight/logs
mkdir -p ~/.gitconfig.d

cd ~/dev-env
docker compose up -d

# Fix permissions
docker compose exec -u root dev bash -c \
  "chown -R dev:dev /home/dev/projects"

# Install at daemon and trigger-watcher cron
sudo apt-get install -y at
sudo systemctl enable --now atd
(crontab -l 2>/dev/null; echo "* * * * * bash ~/dev-env/trigger-watcher.sh >> ~/overnight/trigger-watcher.log 2>&1") | crontab -
```

#### One-time auth inside the container

```bash
docker compose exec dev bash

git config --global user.name "Your Name"
git config --global user.email "you@example.com"
gh auth login
claude login    # subscription auth, not API key — see gotchas below
```

</details>

---

## What You Get

After setup completes, log out and SSH back in:

```
$ ssh ubuntu@my-dev-server

  ┌─────────────────────────────┐
  │  [1] Claude Code            │
  │  [2] Container bash         │
  │  [3] Host shell             │
  └─────────────────────────────┘
```

**The server is running:**
- Docker container (`claude-dev`) with Claude Code, Node.js 22, npm, Bun, AWS CLI v2, GitHub CLI, ripgrep, fzf, zsh
- Tailscale mesh VPN — SSH from any device, no open ports
- tmux for session persistence — disconnect and reconnect without losing state

**Automation is wired up:**
- SSH login menu — press Enter to land in Claude Code
- `/plan-overnight` slash command — plan tasks, schedule them, go to sleep
- `trigger-watcher` cron — detects scheduled tasks every minute, queues them via `at`
- Overnight task logs in `~/overnight/logs/`

**Everything persists across container rebuilds** (bind-mounted volumes):

| Host path | Container path | What it stores |
|-----------|---------------|----------------|
| `~/.claude` | `/home/dev/.claude` | Auth tokens, settings, history |
| `~/.claude.json` | `/home/dev/.claude.json` | Onboarding state |
| `~/projects` | `/home/dev/projects` | Your code repos |
| `~/overnight` | `/home/dev/overnight` | Task files + run logs |
| `~/.gitconfig.d` | `/home/dev/.gitconfig.d` | Git config |
| `~/.ssh` | `/home/dev/.ssh` | SSH keys (read-only) + known_hosts |

---

## One-Command Access

The login menu works from **any SSH client on any device** — phone, tablet, someone else's laptop. No client-side config needed.

If an existing tmux session is running (e.g. from an overnight task), you'll reattach to it and see exactly where things left off.

**Bypass the menu entirely:**

```bash
# Force plain shell (e.g. in scripts or automation)
ssh dev-server -t "NO_CLAUDE=1 bash"
```

---

## Overnight Autonomous Workflows

This is the real payoff. Define tasks, SSH in, detach, and go to sleep.

### Option A: Interactive planning with `/plan-overnight` (recommended)

Use the `/plan-overnight` slash command inside Claude Code. It reads your TODO.md, open GitHub issues, and recent git log across all projects, then collaboratively builds a task file and schedules it — all without leaving Claude.

```bash
ssh ubuntu@my-dev-server
# → auto-enters Claude Code via menu

# Inside Claude Code:
/plan-overnight              # optionally: /plan-overnight auth refactor

# Claude will:
#  1. Scan all git repos under the current directory
#  2. Show open TODOs + GitHub issues across all projects
#  3. Suggest tasks targeting ~6h of runtime
#  4. Iterate with you until confirmed
#  5. Write ~/overnight/tasks-<project>.txt
#  6. Ask what time to run → write a .scheduled sidecar file

# That's it. Close your laptop. Sleep.
# The host trigger-watcher cron picks up the sidecar within 1 minute
# and queues the job via `at` using docker exec.
```

**How scheduling works without leaving the container:**

Task files and logs live in `~/overnight/` which is bind-mounted to the host at `~/overnight/`. When `/plan-overnight` confirms a time, it writes a sidecar:

```
~/overnight/tasks-ainbox.txt           ← task definitions
~/overnight/tasks-ainbox.txt.scheduled ← contains "23:00" (written by plan-overnight)
~/overnight/tasks-ainbox.txt.triggered ← renamed here after host picks it up
~/overnight/logs/overnight-ainbox-*.md ← run log (written by run-tasks.sh)
```

The host cron runs `trigger-watcher.sh` every minute. When it finds a `.scheduled` file it runs:
```bash
echo "docker exec claude-dev bash -c 'bash ~/dev-env/run-tasks.sh ~/overnight/tasks-ainbox.txt'" | at 23:00
```

Because `docker exec` runs outside the Claude session, `CLAUDECODE` is never set and `claude -p` works freely inside the container.

[`run-tasks.sh`](run-tasks.sh) parses the task file and runs each task via `claude -p --dangerously-skip-permissions` with its own timeout, logging output to a Markdown file with per-task commit history.

**Task file format** (`~/overnight/tasks-<project>.txt`):
```
# Tasks for myproject — 2026-02-18
# Estimated total runtime: ~3h (1L + 2M)

---
desc: [L] Add OAuth2 login flow
timeout: 3600
dir: /home/dev/myproject
prompt: Implement OAuth2 login with Google in src/auth/. Add callback handler at
  /auth/google/callback, store session in Redis using the existing client in src/lib/redis.ts.
  Follow patterns in src/auth/local.ts. Write integration tests in tests/auth/.
  Run tests. Commit with descriptive message.

---
desc: [M] Add rate limiting to public API endpoints
timeout: 1800
dir: /home/dev/myproject
prompt: Add rate limiting to all routes in src/api/public/. Use express-rate-limit,
  follow the existing middleware pattern in src/middleware/auth.ts.
  Limit to 100 req/min per IP. Write tests. Run tests. Commit.
```

### Option B: Manual script editing

Edit [`overnight-tasks.sh`](overnight-tasks.sh) directly to hardcode tasks, then run it:

```bash
tmux new -s overnight
cd ~/project
bash ~/dev-env/overnight-tasks.sh
# Detach: Ctrl+A, then D
```

---

Next morning — SSH in. The menu will reattach to your running tmux session automatically.

```bash
ssh ubuntu@my-dev-server
# → reattaches to existing tmux session

# Or pull from your laptop
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

| Provider | Spec | Monthly |
|----------|------|---------|
| **Hetzner CX22** | 2 vCPU, 4 GB, 40 GB | ~EUR 4.50 |
| **AWS EC2 t3.medium** (1yr reserved) | 2 vCPU, 4 GB, 30 GB | ~$22 |
| **DigitalOcean** | 2 vCPU, 4 GB, 80 GB | ~$24 |
| **Linode 4GB** | 2 vCPU, 4 GB, 80 GB | ~$24 |
| **AWS EC2 t3.medium** (on-demand) | 2 vCPU, 4 GB, 30 GB | ~$32 |

Tailscale is free. All providers include enough bandwidth for dev work.

> AWS Spot Instances can bring EC2 down to ~$9–10/mo. You'll need to handle occasional interruptions.

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
| Plan overnight tasks | `/plan-overnight` (inside Claude Code) |
| Run tasks manually (host) | `docker exec claude-dev bash -c 'bash ~/dev-env/run-tasks.sh ~/overnight/tasks-<name>.txt'` |
| Run tasks manually (container) | `bash ~/dev-env/run-tasks.sh ~/overnight/tasks-<name>.txt` (outside Claude session) |
| View overnight log | `tail -f ~/overnight/logs/overnight-*.md` |
| Check scheduled jobs | `atq` (on host) |
| View trigger watcher log | `tail -f ~/overnight/trigger-watcher.log` (on host) |
| Overnight script (manual) | `bash ~/dev-env/overnight-tasks.sh` |
| Daily health check | `bash ~/dev-env/git-check.sh` |
| Health check (git only) | `SKIP_ANALYSIS=1 bash ~/dev-env/git-check.sh` |
| View health check log | `tail -f ~/git-check.log` |
| Fix permissions | `docker compose exec -u root dev bash -c "chown -R dev:dev /home/dev/.claude /home/dev/project"` |
| Re-auth Claude | `claude login` |

---

## License

MIT
