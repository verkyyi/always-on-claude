# Deployment

## Quick reference

| Action | Slash command | Script fallback |
|---|---|---|
| Provision (AWS) | `/provision` | — |
| Provision (Mac) | `/provision-local` | — |
| Install on server | — | `scripts/deploy/install.sh` |
| Auth setup | Onboarding walks through it | `scripts/deploy/setup-auth.sh` |
| Destroy (AWS) | `/destroy` | `scripts/deploy/destroy.sh` |
| Destroy (Mac) | `/destroy-local` | — |

Slash commands are the primary interface. Scripts exist as fallbacks for automation and environments without Claude Code.

## Configuration

All deployment parameters live in a single `.env` file at the repo root.

```bash
cp .env.example .env
vim .env
```

### Resolution order (later wins)

1. **Defaults** — hardcoded in `scripts/deploy/load-config.sh`
2. **`.env` file** — in repo root
3. **Environment variables** — set at runtime

This means `INSTANCE_TYPE=t3.medium /provision` overrides whatever is in `.env`. If no `.env` exists, all defaults match `.env.example`.

The override mechanism preserves env vars set before sourcing `.env` — env vars always win over file values.

### Variable reference

#### AWS / EC2

| Variable | Default | Purpose |
|---|---|---|
| `INSTANCE_TYPE` | `t4g.small` | EC2 instance type. `*g.*` patterns = arm64, otherwise x86_64 |
| `AWS_REGION` | from `aws configure` | AWS region |
| `VOLUME_SIZE` | `20` | EBS volume size in GB |
| `INSTANCE_NAME` | `claude-dev` | EC2 Name tag + SSH config Host entry |
| `KEY_NAME` | `claude-dev-key` | SSH key pair name |
| `SG_NAME` | `claude-dev-sg` | Security group name |
| `SSH_USER` | `dev` | SSH username on the instance |
| `PROJECT_TAG` | `always-on-claude` | AWS resource tag for identifying resources |

#### Docker

| Variable | Default | Purpose |
|---|---|---|
| `DOCKER_IMAGE` | `ghcr.io/verkyyi/always-on-claude:latest` | Container image (multi-arch) |
| `CONTAINER_NAME` | `claude-dev` | Docker container name |
| `CONTAINER_HOSTNAME` | `claude-dev` | Fixed hostname inside container |

#### Paths

| Variable | Default | Purpose |
|---|---|---|
| `DEV_ENV` | `$HOME/dev-env` | Where the repo is cloned on the server |
| `PROJECTS_DIR` | `$HOME/projects` | Projects directory (bind-mounted into container) |

#### Runtime

| Variable | Default | Purpose |
|---|---|---|
| `DEFAULT_CODE_AGENT` | `claude` | Default assistant launched by the SSH workspace picker (`claude` or `codex`) |

#### Sessions

| Variable | Default | Purpose |
|---|---|---|
| `MAX_SESSIONS` | auto-detect | Max concurrent Claude/Codex sessions. Auto: `min((RAM - 512MB) / 650MB, CPUs)` |

#### AMI build

| Variable | Default | Purpose |
|---|---|---|
| `AMI_BUILD_INSTANCE_TYPE` | `t3.medium` | Instance type for building AMIs |
| `AMI_BUILD_VOLUME_SIZE` | `20` | Volume size for AMI builds |

#### Tailscale

| Variable | Default | Purpose |
|---|---|---|
| `TAILSCALE_HOSTNAME` | — | Tailscale hostname for private access |

#### install.sh options (env vars, not in .env)

| Variable | Default | Purpose |
|---|---|---|
| `LOCAL_BUILD` | `0` | Build Docker image locally instead of pulling from GHCR |
| `NON_INTERACTIVE` | `0` | No longer used (kept for backward compatibility with callers) |
| `AOC_SSH_PASSWORD` | — | Enable password SSH auth and set password |
| `AOC_HEARTBEAT_URL` | — | Claude Code heartbeat webhook URL (requires TOKEN) |
| `AOC_HEARTBEAT_TOKEN` | — | Bearer token for heartbeat webhooks (requires URL) |

## Provisioning (AWS EC2)

### Via slash command

```
/provision
```

Claude walks through the entire setup — SSH keys, security groups, instance launch — and connects you in ~40 seconds with a pre-built AMI.

## Installation (install.sh)

One-line bootstrap for a fresh Ubuntu 24.04 server:

```bash
curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/scripts/deploy/install.sh | bash
```

### Phase 1: Automated (no interaction)

1. **System user**: Verifies `dev` user exists (created by cloud-init via user-data)
2. **System packages**: Docker, Docker Compose, tmux, jq, Node.js 22, GitHub CLI, Claude Code, Codex
3. **Swap**: 2GB swapfile, swappiness=10
4. **earlyoom**: OOM killer — 5% RAM / 10% swap thresholds. Protects SSH/systemd, prefers killing node/claude
5. **OOM score protection**: SSH, Tailscale, SSM agent get score -900
6. **Repository**: Clones `always-on-claude` to `~/dev-env` (or pulls if exists)
7. **Host directories**: Creates `~/.claude/`, `~/.codex/`, `~/projects/`, `~/.claude.json`, etc.
8. **Settings**: Generates `~/.claude/settings.json` with permission bypass, status line, MCP servers
9. **Heartbeat hooks**: If `AOC_HEARTBEAT_URL` + `AOC_HEARTBEAT_TOKEN` set, adds webhook hooks for Notification (idle), Stop, and SessionStart events
10. **tmux config**: Installs `~/.tmux.conf` and `~/.tmux-status.sh`
11. **Schedule bridge**: Installs host `atd`, cron, and a systemd path/service that accepts container schedule requests
12. **SSH config**: Accepts `NO_CLAUDE` env var. Optional password auth via `AOC_SSH_PASSWORD`
13. **Shell integration**: Adds `ssh-login.sh` to `.bash_profile`
14. **Auto-updater**: Installs systemd timer via `install-updater.sh`
15. **CloudWatch alarms**: Memory warning (>80%) and critical (>90%) alarms via SNS
16. **Docker**: Pulls image, starts container, fixes permissions
17. **Provisioned marker**: Writes `~/dev-env/.provisioned` with timestamp and commit

### Auth setup (first SSH login)

Auth is handled by the onboarding flow on first SSH login — the selected assistant walks the user through git config, GitHub auth, host-side assistant login, and container verification interactively. When `DEFAULT_CODE_AGENT=codex`, onboarding uses `codex --login` on the provisioned host; on remote SSH hosts this means completing the device-code browser step Codex shows, which signs the workspace into the user's ChatGPT account for subscription-based Codex access. See `scripts/runtime/onboarding-prompt.txt`.

## Staging verification

Use the staging verifier to test the current local checkout on a disposable EC2 host before deploying to production.

```bash
bash scripts/deploy/verify-staging.sh
```

What it verifies:

1. Launches a fresh Ubuntu 24.04 instance with staging-safe names and tags
2. Uploads the current local repo snapshot instead of pulling `main`
3. Runs `install.sh` remotely with `LOCAL_BUILD=1` by default
4. Verifies host tools, persisted config, container runtime, and boot persistence after reboot
5. If `OPENAI_API_KEY` is set and `DEFAULT_CODE_AGENT=codex`, runs a live `codex exec` check plus a picker-driven `codex-*` tmux session check

Useful overrides:

- `KEEP_ON_FAILURE=1` keeps failed staging resources for debugging
- `KEEP_ON_SUCCESS=1` keeps successful staging resources
- `STAGING_VERIFY_REBOOT=0` skips the reboot phase for faster iteration
- `STAGING_VERIFY_LIVE_AGENT=0` skips live Codex checks
- `INSTANCE_TYPE=t4g.medium` or `INSTANCE_TYPE=t3.medium` lets you choose the target architecture explicitly

## Auto-updater

`install-updater.sh` creates a systemd timer:

- **Service**: `claude-update.service` — runs `scripts/runtime/update.sh`
- **Timer**: `claude-update.timer` — every 6 hours, with up to 15 minutes random jitter
- **Persistent**: Catches up on missed runs after reboot

The timer only checks for updates (git fetch). It never applies changes — that requires `/update`. See [Architecture > Update pipeline](architecture.md#update-pipeline) for details.

## AMI builds

Pre-baked AMIs have Docker + Claude Code + Codex pre-installed for ~40-second provisioning.

### Via GitHub Actions

The `build-ami.yml` workflow builds both arm64 and x86_64 AMIs in parallel:

1. Launches temp EC2 with stock Ubuntu 24.04
2. Runs `install.sh` via SSH (NON_INTERACTIVE=1)
3. Cleans instance (removes SSH host keys, cloud-init state, bash history)
4. Stops container, snapshots AMI
5. Deregisters old AMIs per architecture (keeps 1 per arch, stays under 5 public AMI limit)
6. Makes new AMI public
7. Terminates temp instance

**Triggers**: After Docker image publish, changes to `install.sh`, or manual dispatch.

### Via script (single architecture)

```bash
bash scripts/deploy/build-ami.sh
```

Builds for the architecture specified by `AMI_BUILD_INSTANCE_TYPE`.

## Portable mode

Self-contained single-container deployment. No host setup scripts needed.

### Quick start

```bash
docker run -d --name claude-dev \
  -v claude-data:/home/dev/.claude \
  -v codex-data:/home/dev/.codex \
  -v claude-projects:/home/dev/projects \
  ghcr.io/verkyyi/always-on-claude:portable
```

### With Tailscale (remote SSH access)

```bash
docker run -d --cap-add=NET_ADMIN --name claude-dev \
  -v claude-data:/home/dev/.claude \
  -v codex-data:/home/dev/.codex \
  -v claude-projects:/home/dev/projects \
  -v tailscale-state:/var/lib/tailscale \
  -e TS_AUTHKEY=tskey-auth-xxx \
  ghcr.io/verkyyi/always-on-claude:portable
```

### Via Docker Compose

```bash
docker compose -f docker-compose.portable.yml up -d
```

### Entrypoint flow (entrypoint.sh)

Runs as root, then drops privileges:

1. Creates directories (`~/.claude/`, `~/.codex/`, `~/projects/`, `~/overnight/`, etc.)
2. Handles `.claude.json` — stores real file at `~/.claude/claude.json`, symlinks from `~/.claude.json`
3. Creates `remote-settings.json` (Claude crashes without it)
4. Generates `settings.json` with permission bypass + status line
5. Installs statusline script and tmux config
6. Fixes ownership on all paths
7. Configures `.bash_profile` with portable login script
8. Starts Tailscale (if installed and `TS_AUTHKEY` or persisted state available)
9. Starts cron and at daemons (for overnight scheduling)
10. Drops to `dev` user via `gosu` and sleeps

### Portable environment variables

| Variable | Purpose |
|---|---|
| `TS_AUTHKEY` | Tailscale auth key for auto-connect |
| `TS_HOSTNAME` | Tailscale hostname (default: `claude-dev`) |
| `ANTHROPIC_API_KEY` | API key auth (alternative to `claude login`) |
| `OPENAI_API_KEY` | API key auth for Codex (alternative to `codex login`) |
| `DEFAULT_CODE_AGENT` | Default assistant launched by the picker (`claude` or `codex`) |

### Mac mini agent upgrades

`docker-compose.macmini.yml` runs `scripts/runtime/upgrade-code-agents.sh` whenever the Mac mini container starts. The script runs as the non-root `dev` user:

- Claude Code is updated with `claude update`.
- Codex is installed/updated with npm into `~/.local`, avoiding root-owned global npm directories.
- The latest upgrade log is written to `~/.cache/aoc/agent-upgrade.log` inside the container.

Set `AOC_AUTO_UPGRADE_AGENTS=0` in the compose environment to disable this startup check.

## Tailscale

Private SSH access without exposing ports to the internet.

### Setup via slash command

```
/tailscale
```

Claude installs Tailscale, connects to your network, and optionally locks down the security group to remove public SSH access.

### In portable mode

Set `TS_AUTHKEY` environment variable — entrypoint.sh connects automatically with `--ssh` enabled.

### Manual setup

```bash
# Install
curl -fsSL https://tailscale.com/install.sh | sh

# Connect with SSH enabled
sudo tailscale up --ssh --hostname=claude-dev
```

## Teardown

### AWS (slash command)

```
/destroy
```

Finds all resources tagged `Project=always-on-claude` and deletes them with confirmation. Optionally deletes the SSH key pair and removes `.env.workspace` + SSH config entries.

### AWS (script)

```bash
bash scripts/deploy/destroy.sh
```

### Local Mac

```
/destroy-local
```

## Heartbeat hooks

Monitor workspace health via webhooks. When configured, Claude Code sends HTTP POST requests on:

- **SessionStart**: When a new Claude session begins
- **Stop**: When Claude stops (exit, crash, idle timeout)
- **Notification (idle)**: When Claude shows an idle prompt

Configure via env vars before running `install.sh`:

```bash
export AOC_HEARTBEAT_URL=https://your-endpoint.example.com/heartbeat
export AOC_HEARTBEAT_TOKEN=your-bearer-token
bash scripts/deploy/install.sh
```

Both must be set — if only one is provided, heartbeat hooks are skipped with a warning.

## Password SSH auth

Alternative to key-pair auth, useful for mobile clients that don't support SSH keys:

```bash
export AOC_SSH_PASSWORD=your-password
bash scripts/deploy/install.sh
```

This enables `PasswordAuthentication` and `KbdInteractiveAuthentication` in sshd, and sets the password for the `dev` user.
