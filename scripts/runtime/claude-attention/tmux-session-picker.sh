#!/bin/sh
# fzf popup listing every Claude window with: attention-state dot, branch, dirty flag,
# and ahead/behind vs master. Enter jumps to it. Preview pane shows the live screen
# (tmux capture-pane) so you can see what a session is doing without switching to it.
# Bound to `prefix + j` in ~/.tmux.conf. Invoked inside `tmux display-popup -E`.

list() {
  tmux list-windows -a -F '#{session_name}	#{window_index}	#{window_name}	#{pane_current_path}	#{@claude_state}' \
  | while IFS='	' read -r sess idx name path state; do
      case "$state" in
        needs)   dot='🔴' ;;
        done)    dot='🟢' ;;
        working) dot='🔵' ;;
        looping) dot='🟣' ;;
        *)       dot='⚪' ;;
      esac
      branch='-'; dirty=''
      if [ -d "$path/.git" ] || git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
        branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null)
        [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ] && dirty='✱'
        ab=$(git -C "$path" rev-list --left-right --count master...HEAD 2>/dev/null)
        if [ -n "$ab" ]; then
          behind=$(echo "$ab" | awk '{print $1}'); ahead=$(echo "$ab" | awk '{print $2}')
          [ "${ahead:-0}" != "0" ] && branch="$branch +$ahead"
          [ "${behind:-0}" != "0" ] && branch="$branch -$behind"
        fi
      fi
      # tab-separated: target \t display-line
      printf '%s:%s\t%s  %-5s %-24s %-2s %s\n' "$sess" "$idx" "$dot" "$idx:$name" "$branch" "$dirty" ""
    done
}

sel=$(list | fzf --with-nth=2.. --delimiter='\t' \
  --prompt='session > ' --height=100% --border --ansi \
  --header='🔴 answer me  🟢 done/stopped  🔵 working  ✱ dirty   [enter] jump' \
  --preview='tmux capture-pane -ep -t {1} | tail -40' \
  --preview-window='down,60%,wrap' \
  | cut -f1)

[ -n "$sel" ] && tmux switch-client -t "${sel%%:*}" \; select-window -t "$sel"
