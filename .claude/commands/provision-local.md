You are orchestrating the setup of an always-on Claude Code workspace on the user's local Mac. You will run all commands yourself, only pausing when the user needs to do something in System Settings or a browser.

## Context

- macOS version: !`sw_vers 2>&1`
- Architecture: !`uname -m`
- Docker status: !`docker info 2>&1 | head -5 || echo "not installed"`
- Existing workspace: !`cat .env.workspace 2>/dev/null || echo "NOT FOUND"`
- Homebrew: !`brew --version 2>/dev/null || echo "not installed"`

---

## Before you start

If the existing workspace check shows `WORKSPACE_TYPE=local-mac`, ask if they want to re-run setup (idempotent) or skip.

If `$ARGUMENTS` is provided, parse it for preferences. Otherwise use defaults.

---

## Step 1 — Confirm plan

```
I'll set up this Mac as an always-on Claude Code server:

  Hostname:  $(hostname -s)
  Docker:    (detected status)

  What I'll do:
    1. Install prerequisites via Homebrew (tmux, git, gh, node, etc.)
    2. Install/verify Docker (Desktop or Colima)
    3. Install Claude Code CLI
    4. Pull and start the workspace container
    5. Set up authentication (git, GitHub, Claude)
    6. Enable SSH for remote access
    7. Configure auto-start on boot

Press Enter to proceed, or tell me what to change.
```

---

## Step 2 — Xcode CLI tools

```bash
xcode-select -p 2>&1 || echo "not installed"
```

If not installed:
```bash
xcode-select --install
```
Tell the user to click Install in the dialog and wait. Then continue.

---

## Step 3 — Homebrew

```bash
command -v brew && brew --version || echo "not installed"
```

If not installed:
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

---

## Step 4 — System packages

Install each if missing:
```bash
for pkg in tmux git gh node@22 jq ripgrep fzf; do
    brew list "$pkg" 2>/dev/null && echo "$pkg: installed" || brew install "$pkg"
done
```

Link node@22 if `node` isn't on PATH:
```bash
command -v node || brew link --overwrite node@22
```

---

## Step 5 — Docker

Check Docker status:
```bash
docker info 2>&1 | head -3
```

If Docker is not installed, ask the user:
- **Docker Desktop** — GUI, easy, `brew install --cask docker` (free for personal use)
- **Colima** — CLI, lightweight, `brew install colima docker docker-compose && colima start`

If installed but not running, tell the user to start Docker Desktop / `colima start`.

Fix App Translocation quarantine (Docker CLI symlinks break when macOS runs Docker from a randomized temp path):
```bash
if [[ -d /Applications/Docker.app ]] && xattr -p com.apple.quarantine /Applications/Docker.app 2>/dev/null; then
    xattr -d com.apple.quarantine /Applications/Docker.app
    echo "Removed quarantine attribute — quit and reopen Docker Desktop"
fi
```
If the attribute was removed, tell the user to quit and reopen Docker Desktop before continuing.

Verify docker compose works:
```bash
docker compose version
```

---

## Step 6 — Claude Code

```bash
command -v claude && claude --version || echo "not installed"
```

If not installed:
```bash
curl -fsSL https://claude.ai/install.sh | bash
```

---

## Step 7 — Repository

```bash
if [[ -d ~/dev-env/.git ]]; then
    git -C ~/dev-env pull --ff-only
    echo "updated"
else
    git clone https://github.com/verkyyi/always-on-claude.git ~/dev-env
    echo "cloned"
fi
```

---

## Step 8 — Host directories

```bash
mkdir -p ~/.claude/commands ~/.claude/debug ~/.config/gh ~/projects ~/.gitconfig.d ~/.ssh
[[ -f ~/.claude.json ]] || echo '{}' > ~/.claude.json
[[ -f ~/.ssh/known_hosts ]] || touch ~/.ssh/known_hosts
```

Copy statusline and tmux config:
```bash
cp ~/dev-env/scripts/runtime/statusline-command.sh ~/.claude/statusline-command.sh 2>/dev/null
chmod +x ~/.claude/statusline-command.sh 2>/dev/null
cp ~/dev-env/scripts/runtime/tmux.conf ~/.tmux.conf 2>/dev/null
cp ~/dev-env/scripts/runtime/tmux-status.sh ~/.tmux-status.sh 2>/dev/null
chmod +x ~/.tmux-status.sh 2>/dev/null
```

---

## Step 9 — Start container

```bash
cd ~/dev-env && docker compose -f docker-compose.yml -f docker-compose.mac.yml pull
cd ~/dev-env && docker compose -f docker-compose.yml -f docker-compose.mac.yml up -d
```

Fix permissions:
```bash
cd ~/dev-env && docker compose -f docker-compose.yml -f docker-compose.mac.yml exec -T -u root dev bash -c "chown -R dev:dev /home/dev/projects /home/dev/.claude" 2>/dev/null || true
```

Verify:
```bash
docker ps --format '{{.Names}}' | grep claude-dev
```

---

## Step 10 — Authentication

Tell the user what to expect (git config, GitHub CLI login, Claude login — each needs browser auth), then run:

```bash
cd ~/dev-env && docker compose -f docker-compose.yml -f docker-compose.mac.yml exec -it dev bash /home/dev/dev-env/scripts/deploy/setup-auth.sh
```

---

## Step 11 — Enable SSH (Remote Login)

Check status:
```bash
systemsetup -getremotelogin 2>/dev/null || echo "cannot check"
```

If not enabled, tell the user:
"Enable Remote Login: System Settings > General > Sharing > Remote Login > toggle ON"

Wait for user confirmation, then verify:
```bash
ssh -o ConnectTimeout=3 localhost "echo ok" 2>&1
```

Add AcceptEnv for NO_CLAUDE:
```bash
grep -q 'AcceptEnv NO_CLAUDE' /etc/ssh/sshd_config 2>/dev/null || echo 'AcceptEnv NO_CLAUDE' | sudo tee -a /etc/ssh/sshd_config > /dev/null
```

Check macOS firewall:
```bash
/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null
```

If firewall is enabled, warn the user to allow incoming SSH connections in System Settings > Network > Firewall > Options.

---

## Step 12 — Launchd agents (auto-start)

```bash
bash ~/dev-env/scripts/deploy/install-updater-mac.sh
bash ~/dev-env/scripts/deploy/autostart-mac.sh
```

---

## Step 13 — Shell integration

Add to `~/.zprofile` (Mac's default login shell config):
- Homebrew shellenv (if not present)
- `~/.local/bin` to PATH (if not present)
- Source `ssh-login.sh` (if not present)

Show the user what you're adding and confirm before editing.

---

## Step 14 — Shell aliases

Add to `~/.zshrc`:
```bash
# Claude Code workspace shortcuts
alias cc="bash ~/dev-env/scripts/runtime/start-claude.sh"
alias ccc="docker exec -it claude-dev bash -l"
```

If aliases already exist, update them. Tell the user to run `source ~/.zshrc`.

---

## Step 15 — Write workspace info

```bash
cat > .env.workspace << EOF
# Provisioned $(date +%Y-%m-%d)
WORKSPACE_TYPE=local-mac
HOSTNAME=$(hostname -s)
DEV_ENV=$HOME/dev-env
EOF
```

---

## Step 16 — Energy settings

Warn the user:
```
IMPORTANT: For always-on use, configure your Mac to stay awake:
  System Settings > Energy Saver (or Battery > Options)
  - Enable "Prevent automatic sleeping when the display is off"
  - Optionally enable "Wake for network access"
```

---

## Step 17 — Optional Tailscale

Ask if the user wants to set up Tailscale for private remote access:
- If yes, tell them to run `/tailscale` after this completes
- If no, they can access via local network SSH

---

## Step 18 — Summary

```
Local Mac workspace setup complete!

  Hostname:  $(hostname -s)
  Container: claude-dev (running)

  From this Mac:
    cc   — workspace picker
    ccc  — container shell

  From other devices:
    ssh USER@HOSTNAME

  Auto-start:  enabled (launchd)
  Auto-update: enabled (every 6 hours)

  Optional next steps:
    /tailscale  — private access from anywhere
    /destroy-local — tear down this workspace
```

---

## Error handling

- **Docker Desktop not running**: guide user to start it, don't retry endlessly
- **Xcode CLI tools dialog**: wait for user to complete install
- **SSH not enabled**: guide through System Settings, don't try to force-enable
- **Firewall blocking SSH**: warn, don't disable firewall
- **Colima issues**: suggest Docker Desktop as fallback

Do NOT blindly retry failed commands. Diagnose and fix, or ask the user.
