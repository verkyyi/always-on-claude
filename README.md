# Always-On Claude Code

Your own persistent Claude Code workspace in the cloud. SSH in from any device, reconnect where you left off.

**~$30/mo on AWS. One command to set up. ~40 seconds to launch.**

---

## The Problem

| Running Claude Code locally... | Always-On Claude Code |
|---|---|
| Dies when your laptop closes | Runs 24/7 in the cloud |
| Tied to one machine | SSH from laptop, phone, tablet |
| Session lost on disconnect | Reconnect and pick up where you left off |
| 15+ manual setup steps | One command |

---

## Quick Start

### Prerequisites

- **Mac** with Terminal
- **AWS account** with CLI configured (`brew install awscli && aws configure`)
- **Claude subscription** (Pro or Max) — you bring your own auth

### Launch (~40 seconds)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/scripts/deploy/provision.sh)
```

This creates an EC2 instance with Claude Code ready to go. You'll see a summary with your SSH command when it's done.

### Connect

```bash
ssh -i ~/.ssh/claude-dev-key.pem ubuntu@<YOUR_IP>
```

You'll see a login menu — press Enter for Claude Code.

### First-time auth (inside the container)

Choose option `[2]` for container bash, then:

```bash
bash ~/dev-env/scripts/deploy/setup-auth.sh
```

This walks you through git config, GitHub CLI, and Claude login (each needs a browser).

### Tear down

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/scripts/deploy/destroy.sh)
```

Finds all resources by tag, confirms with you, deletes everything.

---

## What You Get

```
Your Mac / Phone / Tablet
    │
    └── SSH
         └── Ubuntu 24.04 (EC2 t3.medium, 30GB)
              ├── Docker container (claude-dev)
              │    ├── Claude Code
              │    ├── Node.js 22, Bun, npm
              │    ├── Git, GitHub CLI, AWS CLI
              │    └── Your project repos
              ├── tmux (session persistence)
              └── Workspace picker on SSH connect
```

**Everything persists** — auth, settings, repos, tmux sessions, Claude history — all survive container restarts and reconnects.

**Built-in slash commands:**
- `/workspace` — manage git worktrees from inside Claude (create, delete, list)

---

## How It Works

| Component | Purpose |
|---|---|
| **Pre-built AMI** | Docker + Claude Code pre-installed, published to AWS (~40s boot) |
| **Docker container** | Isolated workspace with dev tools, bind-mounted for persistence |
| **tmux** | Sessions survive SSH disconnects |
| **Login menu** | SSH in → choose Claude Code, bash, or host shell |

For detailed implementation docs, see:

- [Docker architecture](docs/docker-architecture.md) — container config, volumes, networking
- [CI/CD pipelines](docs/ci-cd.md) — Docker image + AMI build workflows
- [Deployment scripts](docs/deployment-scripts.md) — install.sh, provision.sh, build-ami.sh internals

---

## Cost

| What | Cost |
|---|---|
| EC2 t3.medium (on-demand) | ~$30/mo |
| 30GB gp3 EBS | ~$2.40/mo |
| **Total** | **~$32/mo** |

Stop the instance when not in use to save money. No additional fees — you bring your own Claude subscription.

---

## BYO Auth

We provide the runtime. You bring your own Claude authentication:

- **API key** — set `ANTHROPIC_API_KEY`, pay-per-token, no caps
- **Subscription** — run `claude login` with your Pro/Max account

We never provide, share, or manage Claude credentials.

---

## Coming Soon

- **Claude-guided lifecycle** — `/provision` and `/destroy` slash commands that let Claude orchestrate AWS operations, handle errors, and walk you through setup interactively. See [roadmap details](docs/claude-guided-lifecycle.md).

---

## License

MIT
