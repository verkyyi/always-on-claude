# cwclean [--prune] — audit cw worktrees; prune ones whose branch is merged to master.
#   Dry-run by default (just prints the table). --prune removes worktrees that are
#   merged AND clean AND have no live tmux session, then force-deletes the branch.
#   "merged" = branch tip is an ancestor of master OR its tree is identical to master
#   (so squash-merged PRs are correctly detected — see branch-cleanup-content-verify).
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
        # skip main worktree, current worktree, detached HEAD, and master itself
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
