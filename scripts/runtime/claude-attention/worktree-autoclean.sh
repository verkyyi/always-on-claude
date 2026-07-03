#!/bin/bash
# worktree-autoclean.sh — headless pruning of merged, unattached git worktrees.
# Runs from launchd (com.verkyyi.worktree-autoclean). Safe by construction:
# a worktree is removed ONLY when ALL of these hold:
#   * it is not the main worktree
#   * its branch is not protected (master/main/test/always-on)
#   * no live tmux pane is cd'd inside it   (== "not attached to a session")
#   * it is clean (no uncommitted changes)
#   * it is merged: a MERGED PR exists for the branch on GitHub, OR the branch
#     tip is an ancestor of origin/master
# Fail-safe: if tmux is not running we cannot tell what's attached, so we SKIP.
# Pass --dry-run to print decisions without removing anything.
set -u
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

REPO_ROOT="/Users/verkyyi/projects/24haowan-monorepo"
LOG="/Users/verkyyi/.claude/worktree-autoclean.log"
PROTECTED_RE='^(master|main|test|always-on)$'

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
say() { if [ "$DRY" = 1 ]; then echo "$*"; else log "$*"; fi; }

command -v git >/dev/null 2>&1 || { say "git not found; abort"; exit 0; }
[ -d "$REPO_ROOT/.git" ] || { say "repo root missing; abort"; exit 0; }

# Fail-safe: require a live tmux server so the "attached" check is meaningful.
if ! tmux info >/dev/null 2>&1; then
  say "tmux not running — skipping (cannot determine attached sessions)"; exit 0
fi
LIVE="$(tmux list-panes -a -F '#{pane_current_path}' 2>/dev/null)"

git -C "$REPO_ROOT" fetch -q origin master 2>/dev/null
MASTER="$(git -C "$REPO_ROOT" rev-parse --verify -q origin/master 2>/dev/null \
  || git -C "$REPO_ROOT" rev-parse --verify -q master)"
[ -z "$MASTER" ] && { say "cannot resolve master; abort"; exit 0; }

# One network call: names of branches with a MERGED PR (covers squash-merges).
MERGED_PRS="$(gh -R GuangZhouShanyouGame/24haowan-monorepo pr list \
  --state merged --limit 400 --json headRefName -q '.[].headRefName' 2>/dev/null)"

removed=0; kept=0
dir=""; head=""; branch=""
process() {
  [ -z "$dir" ] && return
  # skip main worktree and detached / no-branch worktrees
  if [ "$dir" = "$REPO_ROOT" ] || [ -z "$branch" ]; then return; fi
  if printf '%s\n' "$branch" | grep -Eq "$PROTECTED_RE"; then
    say "KEEP  $branch  (protected)"; kept=$((kept+1)); return
  fi
  if printf '%s\n' "$LIVE" | grep -qxF "$dir"; then
    say "KEEP  $branch  (live tmux session)"; kept=$((kept+1)); return
  fi
  if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
    say "KEEP  $branch  (dirty — uncommitted changes)"; kept=$((kept+1)); return
  fi
  local merged=""
  if printf '%s\n' "$MERGED_PRS" | grep -qxF "$branch"; then
    merged="merged-PR"
  elif git -C "$REPO_ROOT" merge-base --is-ancestor "$head" "$MASTER" 2>/dev/null; then
    merged="ancestor-of-master"
  fi
  if [ -z "$merged" ]; then
    say "KEEP  $branch  (not merged)"; kept=$((kept+1)); return
  fi
  if [ "$DRY" = 1 ]; then
    echo "PRUNE $branch  ($merged)  -> ${dir##*/}"; removed=$((removed+1)); return
  fi
  if git -C "$REPO_ROOT" worktree remove "$dir" 2>/dev/null; then
    git -C "$REPO_ROOT" branch -D "$branch" >/dev/null 2>&1
    log "PRUNED $branch ($merged) — removed ${dir##*/} + deleted branch"
    removed=$((removed+1))
  else
    log "FAIL  could not remove $dir (branch $branch)"
  fi
}

while IFS= read -r line; do
  case "$line" in
    "worktree "*) process; dir="${line#worktree }"; head=""; branch="" ;;
    "HEAD "*)     head="${line#HEAD }" ;;
    "branch "*)   branch="${line#branch refs/heads/}" ;;
  esac
done <<EOF
$(git -C "$REPO_ROOT" worktree list --porcelain)
EOF
process   # flush last block

git -C "$REPO_ROOT" worktree prune 2>/dev/null   # drop stale admin entries
say "done: pruned=$removed kept=$kept"
# keep the log from growing unbounded
if [ "$DRY" = 0 ] && [ -f "$LOG" ]; then tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; fi
exit 0
