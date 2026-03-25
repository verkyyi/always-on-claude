# Always-On Claude Code

Your own persistent Claude Code workspace on AWS. SSH in from any device, reconnect where you left off.

**~$14/mo on AWS. One slash command to set up.**

---

## The Problem

| Running Claude Code locally... | Always-On Claude Code |
|---|---|
| Dies when your laptop closes | Runs 24/7 on a server or Mac |
| Tied to one machine | SSH from laptop, phone, tablet |
| Session lost on disconnect | Reconnect and pick up where you left off |
| No background tasks | Claude keeps working while you sleep |

---

## Two Options

| | Hosted | Cloud (AWS EC2) |
|---|---|---|
| **Best for** | Zero setup, no AWS needed | Dedicated remote server |
| **Cost** | $39/mo | ~$14/mo (EC2 + EBS) |
| **Setup** | [Pay and connect](https://aoc.ainbox.io) | `/provision` |
| **Teardown** | Cancel subscription | `/destroy` |
| **Networking** | Public IP | Public IP or Tailscale |
| **You manage** | Nothing | AWS account + instance |

### Hosted

Don't want to manage infrastructure? **[Always-On Claude Hosted](https://aoc.ainbox.io)** gives you a fully managed workspace — no AWS account, no Docker, no setup. Pay, get an SSH key, connect.

---

## Quick Start

### Prerequisites

- Claude Code CLI installed (`npm install -g @anthropic-ai/claude-code`)
- **Claude subscription** active (Pro or Max)
- **AWS account** with CLI configured (`brew install awscli && aws configure`)

### 1. Clone and provision

```bash
git clone https://github.com/verkyyi/always-on-claude.git
cd always-on-claude
claude
```

Inside the Claude Code session:

```text
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

```text
/destroy
```

---

## Slash Commands

All lifecycle operations run from inside a Claude Code session in this repo:

| Command | What it does |
|---|---|
| `/provision` | Launch a new workspace on AWS (~40s) |
| `/destroy` | Tear down all AWS resources |
| `/update` | Apply updates to a running workspace |
| `/tailscale` | Set up Tailscale for private SSH |
| `/workspace` | Manage repos and git worktrees |

---

## What You Get

```text
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
# Provision EC2
bash <(curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/scripts/deploy/provision.sh)

# Destroy EC2
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
