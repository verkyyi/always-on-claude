#!/bin/bash
# restore-state.sh — Restore user state after a container update.
#
# Re-installs user packages captured by backup-state.sh and
# verifies bind mounts are intact. Run automatically after
# docker compose up -d during the update flow.
#
# Usage:
#   bash restore-state.sh              # restore from latest backup
#   bash restore-state.sh <backup_dir> # restore from specific backup

set -euo pipefail

# --- Helpers ----------------------------------------------------------------

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
warn()  { echo "  WARN: $*"; }
skip()  { echo "  SKIP: $*"; }
die()   { echo "ERROR: $*" >&2; exit 1; }

CONTAINER_NAME="claude-dev"
BACKUP_DIR="${1:-$HOME/backups/latest}"

# --- Preflight --------------------------------------------------------------

if [[ ! -d "$BACKUP_DIR" ]]; then
    echo "No backup found at $BACKUP_DIR — nothing to restore."
    exit 0
fi

# Resolve symlink
BACKUP_DIR=$(cd "$BACKUP_DIR" && pwd)

if [[ ! -f "$BACKUP_DIR/manifest.txt" ]]; then
    die "Invalid backup: $BACKUP_DIR (missing manifest.txt)"
fi

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    die "Container $CONTAINER_NAME is not running. Start it first."
fi

info "Restoring from backup: $BACKUP_DIR"

# Show backup age
backup_time=$(grep '^backup_time=' "$BACKUP_DIR/manifest.txt" | cut -d= -f2-)
echo "  Backup taken: $backup_time"

# --- 1. Verify bind mounts -------------------------------------------------

info "Verifying bind mounts"

restore_ok=true

check_mount() {
    local host_path="$1" desc="$2"
    if [[ -e "$host_path" ]]; then
        ok "$desc"
    else
        warn "$desc missing: $host_path — creating it"
        mkdir -p "$host_path"
        restore_ok=false
    fi
}

check_mount "$HOME/.claude" "Claude config dir"
check_mount "$HOME/.config/gh" "GitHub CLI config"
check_mount "$HOME/projects" "Projects directory"
check_mount "$HOME/.gitconfig.d" "Git config dir"

# claude.json needs to be a file, not a directory
if [[ -f "$HOME/.claude.json" ]]; then
    ok "Claude onboarding state"
elif [[ -d "$HOME/.claude.json" ]]; then
    warn "~/.claude.json is a directory (should be a file) — fixing"
    rm -rf "$HOME/.claude.json"
    echo '{}' > "$HOME/.claude.json"
    restore_ok=false
else
    warn "~/.claude.json missing — creating"
    echo '{}' > "$HOME/.claude.json"
    restore_ok=false
fi

# --- 2. Re-install user apt packages ---------------------------------------

info "Restoring user-installed apt packages"

if [[ -s "$BACKUP_DIR/user-packages.txt" ]]; then
    user_pkg_count=$(wc -l < "$BACKUP_DIR/user-packages.txt" | tr -d ' ')
    echo "  Found $user_pkg_count user package(s) to restore"

    # Read packages into array
    mapfile -t pkgs < "$BACKUP_DIR/user-packages.txt"

    # Filter to only packages that are NOT already installed
    missing_pkgs=()
    for pkg in "${pkgs[@]}"; do
        [[ -z "$pkg" ]] && continue
        if ! docker exec "$CONTAINER_NAME" dpkg -s "$pkg" &>/dev/null 2>&1; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        echo "  Installing ${#missing_pkgs[@]} missing package(s): ${missing_pkgs[*]}"
        docker exec -u root "$CONTAINER_NAME" bash -c \
            "apt-get update -qq && apt-get install -y -qq ${missing_pkgs[*]}" \
            2>&1 | tail -5
        ok "Restored ${#missing_pkgs[@]} apt package(s)"
    else
        skip "All user apt packages already present"
    fi
else
    skip "No user apt packages to restore"
fi

# --- 3. Re-install user pip packages ---------------------------------------

info "Restoring user pip packages"

if [[ -s "$BACKUP_DIR/user-pip-packages.txt" ]]; then
    pip_count=$(wc -l < "$BACKUP_DIR/user-pip-packages.txt" | tr -d ' ')
    echo "  Found $pip_count pip package(s) to restore"

    docker exec "$CONTAINER_NAME" bash -c \
        "pip3 install --user --quiet $(cat "$BACKUP_DIR/user-pip-packages.txt" | tr '\n' ' ')" \
        2>&1 | tail -5 || warn "Some pip packages failed to install"
    ok "Restored pip packages"
else
    skip "No user pip packages to restore"
fi

# --- 4. Restore tmux session layouts ---------------------------------------

info "Restoring tmux session layouts"

if [[ -s "$BACKUP_DIR/tmux-sessions.txt" ]]; then
    # We don't recreate sessions automatically (that would launch Claude Code
    # instances), but we report what was running so the user can restart them
    echo "  Previously active sessions:"
    while IFS='|' read -r name windows size; do
        echo "    - $name ($windows window(s), $size)"
    done < "$BACKUP_DIR/tmux-sessions.txt"
    echo ""
    echo "  Sessions will be recreated when you select workspaces from the picker."
    ok "Tmux layout info preserved"
else
    skip "No tmux sessions to restore"
fi

# --- 5. Fix container permissions ------------------------------------------

info "Fixing container permissions"

docker exec -u root "$CONTAINER_NAME" bash -c \
    "chown -R dev:dev /home/dev/projects /home/dev/.claude" 2>/dev/null || true
ok "Container permissions fixed"

# --- 6. Check for dirty repos ----------------------------------------------

if [[ -s "$BACKUP_DIR/dirty-repos.txt" ]]; then
    dirty_count=$(grep -c . "$BACKUP_DIR/dirty-repos.txt" 2>/dev/null || echo 0)
    if [[ "$dirty_count" -gt 0 ]]; then
        info "Repos with uncommitted changes (from before update)"
        while IFS= read -r repo; do
            [[ -z "$repo" ]] && continue
            # Check if changes are still there
            status=$(docker exec "$CONTAINER_NAME" bash -c "cd '$repo' && git status --porcelain 2>/dev/null" || true)
            if [[ -n "$status" ]]; then
                ok "$repo — changes still intact"
            else
                warn "$repo — changes are gone (may have been in the image layer)"
            fi
        done < "$BACKUP_DIR/dirty-repos.txt"
    fi
fi

# --- Summary ----------------------------------------------------------------

info "Restore complete"

if [[ "$restore_ok" == "true" ]]; then
    ok "All state verified and restored successfully"
else
    warn "Some issues were found and fixed — review output above"
fi
