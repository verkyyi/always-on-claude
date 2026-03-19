# Always-On Claude Code

Your own persistent Claude Code workspace — on AWS or a local Mac. SSH in from any device, reconnect where you left off.

**Cloud: ~$14/mo on AWS. Local: $0 on your own Mac. One slash command to set up.**

---

## The Problem

| Running Claude Code locally... | Always-On Claude Code |
|---|---|
| Dies when your laptop closes | Runs 24/7 on a server or Mac |
| Tied to one machine | SSH from laptop, phone, tablet |
| Session lost on disconnect | Reconnect and pick up where you left off |
| No background tasks | Claude keeps working while you sleep |

---

## Three Options

| | Hosted | Cloud (AWS EC2) | Local Mac |
|---|---|---|---|
| **Best for** | Zero setup, no AWS needed | Dedicated remote server | Mac mini/Studio on your desk |
| **Cost** | $39/mo | ~$14/mo (EC2 + EBS) | $0 (your hardware) |
| **Setup** | [Pay and connect](https://aoc.ainbox.io) | `/provision` | `/provision-local` |
| **Teardown** | Cancel subscription | `/destroy` | `/destroy-local` |
| **Networking** | Public IP | Public IP or Tailscale | LAN SSH or Tailscale |
| **You manage** | Nothing | AWS account + instance | Docker + Mac |

Cloud and Local run the same Docker container, same workspace picker, same auth flow.

### Hosted

Don't want to manage infrastructure? **[Always-On Claude Hosted](https://aoc.ainbox.io)** gives you a fully managed workspace — no AWS account, no Docker, no setup. Pay, get an SSH key, connect.

---

## Quick Start: Cloud (AWS)

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

---

## Quick Start: Local Mac

> **⚠️ Local Mac provisioning is under active testing.** Known issues: bash 3.2 compatibility in runtime scripts, Docker Desktop CLI symlink breakage from macOS App Translocation. See [mac provisioning issues](#known-issues-local-mac).

### Prerequisites

- **Mac** (mini, Studio, or any Mac you'll keep running) with macOS 13+
- **Claude subscription** active (Pro or Max)
- Docker Desktop or Colima (the setup will guide you)

### 1. Clone and provision

```bash
git clone https://github.com/verkyyi/always-on-claude.git
cd always-on-claude
claude
```

Inside the Claude Code session:

```
/provision-local
```

Claude installs prerequisites via Homebrew, sets up Docker, pulls the container, configures SSH, and sets up launchd for auto-start.

### 2. From this Mac

```bash
cc    # workspace picker
ccc   # container shell
```

### 3. From other devices

Enable Remote Login in System Settings > General > Sharing, then:

```bash
ssh your-user@your-mac-hostname
```

Same login menu as the cloud version — press Enter for Claude Code.

### 4. Tear down

```
/destroy-local
```

### Tips for always-on use

- **Prevent sleep**: System Settings > Energy Saver > "Prevent automatic sleeping when the display is off"
- **Tailscale**: Run `/tailscale` for private access from anywhere without exposing SSH publicly
- **Auto-login**: Configure in System Settings if you want the Mac to recover unattended after a reboot

---

## Slash Commands

All lifecycle operations run from inside a Claude Code session in this repo:

| Command | What it does |
|---|---|
| `/provision` | Launch a new workspace on AWS (~40s) |
| `/provision-local` | Set up a local Mac as an always-on workspace |
| `/destroy` | Tear down all AWS resources |
| `/destroy-local` | Tear down local Mac workspace |
| `/update` | Apply updates to a running workspace (either type) |
| `/tailscale` | Set up Tailscale for private SSH (either type) |
| `/workspace` | Manage repos and git worktrees |

---

## What You Get

**Cloud (EC2):**
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

**Local Mac:**
```
Your Phone / Tablet / Other Mac
    │
    └── SSH (LAN or Tailscale)
         └── macOS (Mac mini / Studio)
              ├── Docker container (claude-dev)
              │    ├── Claude Code
              │    ├── Node.js 22, Bun, npm
              │    ├── Git, GitHub CLI, AWS CLI
              │    └── Your project repos
              ├── tmux (session persistence)
              ├── launchd (auto-start on boot)
              └── Workspace picker on SSH connect
```

**Everything persists** — auth, settings, repos, tmux sessions, Claude history — all survive container restarts and reconnects.

---

## How It Works

| Component | Purpose |
|---|---|
| **Pre-built AMI** (cloud) | Docker + Claude Code pre-installed (~40s boot) |
| **Homebrew setup** (local) | All tools installed via `brew`, auto-start via launchd |
| **Docker container** | Isolated workspace with dev tools, bind-mounted for persistence |
| **tmux** | Sessions survive SSH disconnects |
| **Login menu** | SSH in → choose Claude Code, bash, or host shell |

---

## Cost

**Cloud (AWS):**

| What | Cost |
|---|---|
| EC2 t4g.small (on-demand) | ~$12/mo |
| 20GB gp3 EBS | ~$1.60/mo |
| **Total** | **~$14/mo** |

Stop the instance when not in use to save money.

**Local Mac:** $0 beyond the hardware you already own (just electricity).

No additional fees for either option — you bring your own Claude subscription.

---

## Script Fallbacks

If you prefer running scripts directly instead of slash commands:

```bash
# Cloud: Provision EC2
bash <(curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/scripts/deploy/provision.sh)

# Cloud: Destroy EC2
bash <(curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/scripts/deploy/destroy.sh)

# Local Mac: Bootstrap
bash scripts/deploy/install-mac.sh
```

For script details, see [deployment scripts](docs/deployment-scripts.md).

---

## Further Reading

- [Docker architecture](docs/docker-architecture.md) — container config, volumes, networking
- [CI/CD pipelines](docs/ci-cd.md) — Docker image + AMI build workflows
- [Deployment scripts](docs/deployment-scripts.md) — install.sh, provision.sh, build-ami.sh internals

---

## Known Issues: Local Mac

| Issue | Status | Workaround |
|---|---|---|
| `mapfile: command not found` on SSH login | Fixed | Runtime scripts updated to use `while read` loops |
| `unbound variable` on empty arrays | Open | `set -u` + empty arrays fails on bash 3.2; need `${arr[@]+"${arr[@]}"}` guards |
| Docker CLI not found after install | Open | macOS App Translocation breaks `/usr/local/bin/docker` symlinks; fix with `xattr -d com.apple.quarantine /Applications/Docker.app` then restart Docker |
| `docker compose up -d` missing mac override | Open | `start-claude.sh` should use `-f docker-compose.yml -f docker-compose.mac.yml` on local-mac workspaces |

---

## License

MIT
