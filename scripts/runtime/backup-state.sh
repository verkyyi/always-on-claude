#!/bin/bash
# backup-state.sh — Snapshot user state before applying updates.
#
# Captures:
#   - Git repos with uncommitted changes (warning only)
#   - User-installed apt packages beyond Dockerfile defaults
#   - tmux session layouts
#   - Bind mount integrity check
#
# Backups are stored in ~/backups/<timestamp>/ on the host.
# Called automatically by update.sh before image updates,
# or manually via the /update slash command.

set -euo pipefail

# --- Helpers ----------------------------------------------------------------

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
warn()  { echo "  WARN: $*"; }
skip()  { echo "  SKIP: $*"; }

CONTAINER_NAME="claude-dev"
BACKUP_DIR="$HOME/backups/$(date +%Y%m%d-%H%M%S)"
BACKUP_LATEST="$HOME/backups/latest"

# --- Preflight --------------------------------------------------------------

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Container not running — nothing to back up."
    exit 0
fi

mkdir -p "$BACKUP_DIR"

info "Backing up user state"

# --- 1. Check for uncommitted changes in git repos -------------------------

info "Checking git repos for uncommitted work"

dirty_repos=()
mapfile -t repos < <(
    docker exec "$CONTAINER_NAME" bash -c \
        'find /home/dev/projects -maxdepth 3 -name .git -type d 2>/dev/null' \
    | sed 's|/.git$||'
)

for repo in "${repos[@]}"; do
    [[ -z "$repo" ]] && continue
    status=$(docker exec "$CONTAINER_NAME" bash -c "cd '$repo' && git status --porcelain 2>/dev/null" || true)
    if [[ -n "$status" ]]; then
        dirty_repos+=("$repo")
        warn "Uncommitted changes: $repo"
        echo "$status" | head -20 | sed 's/^/    /'
        count=$(echo "$status" | wc -l | tr -d ' ')
        if [[ "$count" -gt 20 ]]; then
            echo "    ... and $((count - 20)) more files"
        fi
    fi
done

if [[ ${#dirty_repos[@]} -eq 0 ]]; then
    ok "All repos are clean"
fi

# Write dirty repos list for restore script reference
printf '%s\n' "${dirty_repos[@]}" > "$BACKUP_DIR/dirty-repos.txt" 2>/dev/null || true

# --- 2. Snapshot user-installed packages ------------------------------------

info "Snapshotting user-installed packages"

# Get packages currently installed in container
docker exec "$CONTAINER_NAME" bash -c \
    'apt-mark showmanual 2>/dev/null | sort' \
    > "$BACKUP_DIR/installed-packages.txt" 2>/dev/null || true

# Dockerfile base packages — these ship with the image and don't need restoring
cat > "$BACKUP_DIR/base-packages.txt" <<'BASEPKGS'
build-essential
curl
fzf
gh
git
jq
nodejs
python3
python3-pip
ripgrep
tmux
unzip
vim
zsh
BASEPKGS

# Compute user-added packages (installed minus base)
comm -23 \
    "$BACKUP_DIR/installed-packages.txt" \
    "$BACKUP_DIR/base-packages.txt" \
    > "$BACKUP_DIR/user-packages.txt" 2>/dev/null || true

# Also capture pip packages installed by user
docker exec "$CONTAINER_NAME" bash -c \
    'pip3 list --user --format=freeze 2>/dev/null || true' \
    > "$BACKUP_DIR/user-pip-packages.txt" 2>/dev/null || true

# Also capture npm global packages installed by user
docker exec "$CONTAINER_NAME" bash -c \
    'npm list -g --depth=0 --json 2>/dev/null || echo "{}"' \
    > "$BACKUP_DIR/user-npm-packages.json" 2>/dev/null || true

user_pkg_count=$(wc -l < "$BACKUP_DIR/user-packages.txt" | tr -d ' ')
pip_pkg_count=$(wc -l < "$BACKUP_DIR/user-pip-packages.txt" | tr -d ' ')

if [[ "$user_pkg_count" -gt 0 || "$pip_pkg_count" -gt 0 ]]; then
    ok "Captured $user_pkg_count apt and $pip_pkg_count pip user packages"
else
    ok "No user-installed packages to track"
fi

# --- 3. Export tmux session layouts -----------------------------------------

info "Exporting tmux session layouts"

if tmux list-sessions &>/dev/null 2>&1; then
    tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_width}x#{session_height}' \
        > "$BACKUP_DIR/tmux-sessions.txt" 2>/dev/null || true

    # Capture window/pane layout for each session
    tmux list-windows -a -F '#{session_name}|#{window_index}|#{window_name}|#{window_layout}' \
        > "$BACKUP_DIR/tmux-layouts.txt" 2>/dev/null || true

    session_count=$(wc -l < "$BACKUP_DIR/tmux-sessions.txt" | tr -d ' ')
    ok "Exported $session_count tmux session(s)"
else
    skip "No tmux sessions running"
    touch "$BACKUP_DIR/tmux-sessions.txt"
    touch "$BACKUP_DIR/tmux-layouts.txt"
fi

# --- 4. Verify bind mounts -------------------------------------------------

info "Verifying bind mounts"

mounts_ok=true

check_mount() {
    local host_path="$1" desc="$2"
    if [[ -e "$host_path" ]]; then
        ok "$desc ($host_path)"
    else
        warn "$desc missing: $host_path"
        mounts_ok=false
    fi
}

check_mount "$HOME/.claude" "Claude config dir"
check_mount "$HOME/.claude.json" "Claude onboarding state"
check_mount "$HOME/.config/gh" "GitHub CLI config"
check_mount "$HOME/projects" "Projects directory"
check_mount "$HOME/.ssh" "SSH directory"
check_mount "$HOME/.gitconfig.d" "Git config dir"

echo "$mounts_ok" > "$BACKUP_DIR/mounts-ok.txt"

# --- 5. Write backup manifest -----------------------------------------------

cat > "$BACKUP_DIR/manifest.txt" <<EOF
backup_time=$(date -Iseconds)
container=$CONTAINER_NAME
dirty_repo_count=${#dirty_repos[@]}
user_apt_packages=$user_pkg_count
user_pip_packages=$pip_pkg_count
mounts_ok=$mounts_ok
EOF

# Update latest symlink
ln -sfn "$BACKUP_DIR" "$BACKUP_LATEST"

# --- 6. Prune old backups (keep last 5) ------------------------------------

mapfile -t old_backups < <(
    ls -dt "$HOME/backups"/[0-9]* 2>/dev/null | tail -n +6
)
for old in "${old_backups[@]}"; do
    rm -rf "$old"
done

if [[ ${#old_backups[@]} -gt 0 ]]; then
    ok "Pruned ${#old_backups[@]} old backup(s)"
fi

# --- Summary ----------------------------------------------------------------

info "Backup complete"
echo "  Location: $BACKUP_DIR"

if [[ ${#dirty_repos[@]} -gt 0 ]]; then
    echo ""
    warn "${#dirty_repos[@]} repo(s) have uncommitted changes!"
    echo "  Consider committing or stashing before updating."
    echo ""
fi
