#!/bin/bash
# install.sh — install the Claude multi-session attention layer on this host.
# Idempotent. Copies scripts into ~/.claude, launchd plists into ~/Library/LaunchAgents,
# wires ~/.tmux.conf + ~/.claude/settings.json + ~/.zshrc, and (re)loads the agents.
#
# NOTE: the launchd plists hardcode /Users/verkyyi paths — fine for this host;
# re-templatize if installing elsewhere.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE="$HOME/.claude"
LA="$HOME/Library/LaunchAgents"
mkdir -p "$CLAUDE/hooks" "$LA"

# 1. scripts -> ~/.claude
install -m 755 "$DIR"/hooks/set-claude-state.sh "$CLAUDE/hooks/set-claude-state.sh"
install -m 755 "$DIR"/hooks/guard.py            "$CLAUDE/hooks/guard.py"
for f in next-attention.sh tmux-session-picker.sh gh-glance.sh tmux-spinner.sh \
         classify-sessions.sh worktree-autoclean.sh reapply-tmux-attention.sh; do
  install -m 755 "$DIR/$f" "$CLAUDE/$f"
done
install -m 644 "$DIR/tmux-attention.conf" "$CLAUDE/tmux-attention.conf"

# 2. tmux: ensure ~/.tmux.conf sources the attention conf (idempotent)
sh "$CLAUDE/reapply-tmux-attention.sh" >/dev/null 2>&1 || true

# 3. settings.json hooks (non-destructive deep-merge; needs jq)
if command -v jq >/dev/null 2>&1; then
  tmp="$(mktemp)"
  if [ -f "$CLAUDE/settings.json" ]; then
    jq -s '.[0] * .[1]' "$CLAUDE/settings.json" "$DIR/settings.hooks.json" > "$tmp" && mv "$tmp" "$CLAUDE/settings.json"
  else
    cp "$DIR/settings.hooks.json" "$CLAUDE/settings.json"
  fi
else
  echo "WARN: jq not found — merge $DIR/settings.hooks.json into $CLAUDE/settings.json by hand"
fi

# 4. cwclean zsh function (append once). Embedded as a QUOTED heredoc: it's zsh
#    (not lintable as bash), and a quoted heredoc body is data, so shellcheck
#    skips it and the bundle needs no separate .zsh file.
if ! grep -q 'cwclean()' "$HOME/.zshrc" 2>/dev/null; then
  cat >> "$HOME/.zshrc" <<'CWCLEAN'

# cwclean [--prune] — audit cw worktrees; prune ones whose branch is merged to master.
#   Dry-run by default. --prune removes worktrees that are merged AND clean AND have
#   no live tmux session, then force-deletes the branch. "merged" = ancestor of
#   master OR tree identical to master (so squash-merged PRs are detected).
cwclean() {
  local prune=0; [[ "$1" == "--prune" || "$1" == "-y" ]] && prune=1
  local root main master live dir head branch
  root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "cwclean: not in a git repo"; return 1; }
  main=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')
  echo "cwclean: fetching origin/master…"
  git -C "$main" fetch -q origin master 2>/dev/null
  master=$(git -C "$main" rev-parse --verify -q origin/master 2>/dev/null || git -C "$main" rev-parse --verify -q master)
  [[ -z "$master" ]] && { echo "cwclean: cannot resolve master"; return 1; }
  live=$(tmux list-panes -a -F '#{pane_current_path}' 2>/dev/null)

  local -a prunable prunebranch
  printf '%-52s %-34s %-8s %-6s %s\n' WORKTREE BRANCH MERGED DIRTY LIVE
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) dir="${line#worktree }" ;;
      "HEAD "*)     head="${line#HEAD }" ;;
      "branch "*)   branch="${line#branch refs/heads/}" ;;
      "")
        [[ -z "$dir" ]] && continue
        if [[ "$dir" == "$main" || "$dir" == "$root" || -z "$branch" || "$branch" == "master" ]]; then
          dir=""; head=""; branch=""; continue
        fi
        local merged=no dirty=no islive=no
        if git -C "$main" merge-base --is-ancestor "$head" "$master" 2>/dev/null; then merged=yes
        elif git -C "$main" diff --quiet "$master" "$head" 2>/dev/null; then merged=squash; fi
        [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]] && dirty=yes
        echo "$live" | grep -qx "$dir" && islive=yes
        printf '%-52s %-34s %-8s %-6s %s\n' "${dir##*/}" "$branch" "$merged" "$dirty" "$islive"
        if [[ "$merged" != "no" && "$dirty" == "no" && "$islive" == "no" ]]; then
          prunable+=("$dir"); prunebranch+=("$branch")
        fi
        dir=""; head=""; branch="" ;;
    esac
  done < <(git -C "$main" worktree list --porcelain; echo "")

  local n=${#prunable[@]}
  if (( n == 0 )); then echo "\ncwclean: nothing safe to prune."; return 0; fi
  echo "\ncwclean: $n worktree(s) safe to prune (merged + clean + no live session):"
  local i; for i in {1..$n}; do echo "  - ${prunable[$i]##*/}  [${prunebranch[$i]}]"; done
  if (( ! prune )); then echo "\nRe-run 'cwclean --prune' to remove them."; return 0; fi
  read "REPLY?Remove these $n worktree(s) and delete their branches? [y/N] "
  [[ "$REPLY" == [yY] ]] || { echo "aborted."; return 0; }
  for i in {1..$n}; do
    git -C "$main" worktree remove "${prunable[$i]}" && echo "removed ${prunable[$i]##*/}"
    git -C "$main" branch -D "${prunebranch[$i]}" 2>/dev/null && echo "  deleted branch ${prunebranch[$i]}"
  done
}
CWCLEAN
fi

# 5. launchd agents (spinner / classifier / worktree janitor)
for p in "$DIR"/launchd/*.plist; do
  label="$(basename "$p" .plist)"
  cp "$p" "$LA/$label.plist"
  launchctl unload "$LA/$label.plist" 2>/dev/null || true
  launchctl load -w "$LA/$label.plist"
done

tmux source-file "$HOME/.tmux.conf" 2>/dev/null || true
echo "✓ attention layer installed + agents loaded."
