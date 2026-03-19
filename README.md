# Always-On Claude Code

Your own persistent Claude Code workspace in the cloud. SSH in from any device, reconnect where you left off.

**~$30/mo on AWS. One slash command. ~40 seconds to launch.**

---

## The Problem

| Running Claude Code locally... | Always-On Claude Code |
|---|---|
| Dies when your laptop closes | Runs 24/7 in the cloud |
| Tied to one machine | SSH from laptop, phone, tablet |
| Session lost on disconnect | Reconnect and pick up where you left off |
| No background tasks | Claude keeps working while you sleep |

---

## Quick Start

### Prerequisites

- **Mac** with Claude Code CLI installed (`npm install -g @anthropic-ai/claude-code`)
- **Claude subscription** active (Pro or Max)
- **AWS account** with CLI configured (`brew install awscli && aws configure`)

### 1. Clone and provision

```bash
git clone https://github.com/verkyyi/always-on-claude.git
cd always-on-claude
claude
```

Inside the Claude Code session:

```
/provision
```

Claude walks you through the entire AWS setup — SSH keys, security groups, instance launch — and connects you in ~40 seconds.

### 2. Connect

```bash
ssh claude-dev
```

You'll see a login menu — press Enter for Claude Code.

### 3. First-time auth

From the login menu, choose `[2]` for container bash, then:

```bash
bash ~/dev-env/scripts/deploy/setup-auth.sh
```

This walks you through git config, GitHub CLI, and Claude login (each needs a browser).

### 4. Tear down when done

Back in your local Claude Code session:

```
/destroy
```

Claude finds all resources by tag, confirms with you, and deletes everything.

---

## Slash Commands

All lifecycle operations run from inside a Claude Code session in this repo:

| Command | What it does |
|---|---|
| `/provision` | Launch a new workspace on AWS (~40s) |
| `/destroy` | Tear down all AWS resources |
| `/update` | Apply updates to a running workspace |
| `/tailscale` | Set up Tailscale for private SSH (no public IP needed) |
| `/workspace` | Manage repos and git worktrees on the remote |

---

## What You Get

```
Your Mac / Phone / Tablet
    │
    └── SSH
         └── Ubuntu 24.04 (EC2 t4g.small, 20GB)
              ├── Docker container (claude-dev)
              │    ├── Claude Code
              │    ├── Node.js 22, Bun, npm
              │    ├── Git, GitHub CLI, AWS CLI
              │    └── Your project repos
              ├── tmux (session persistence)
              └── Workspace picker on SSH connect
```

**Everything persists** — auth, settings, repos, tmux sessions, Claude history — all survive container restarts and reconnects.

---

## How It Works

| Component | Purpose |
|---|---|
| **Pre-built AMI** | Docker + Claude Code pre-installed (~40s boot) |
| **Docker container** | Isolated workspace with dev tools, bind-mounted for persistence |
| **tmux** | Sessions survive SSH disconnects |
| **Login menu** | SSH in → choose Claude Code, bash, or host shell |

---

## Cost

| What | Cost |
|---|---|
| EC2 t4g.small (on-demand) | ~$12/mo |
| 20GB gp3 EBS | ~$1.60/mo |
| **Total** | **~$14/mo** |

Stop the instance when not in use to save money. No additional fees — you bring your own Claude subscription.

---

## Script Fallbacks

If you prefer running scripts directly instead of slash commands:

```bash
# Provision
bash <(curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/scripts/deploy/provision.sh)

# Destroy
bash <(curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/scripts/deploy/destroy.sh)
```

For script details, see [deployment scripts](docs/deployment-scripts.md).

---

## Further Reading

- [Docker architecture](docs/docker-architecture.md) — container config, volumes, networking
- [CI/CD pipelines](docs/ci-cd.md) — Docker image + AMI build workflows
- [Deployment scripts](docs/deployment-scripts.md) — install.sh, provision.sh, build-ami.sh internals

---

## License

MIT
