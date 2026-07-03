#!/bin/sh
# Jump to the next Claude window that needs attention.
# Priority: 'needs' (red = answer me) first, then 'done' (green = finished/stopped);
# lowest index first. Bound to `prefix + a` in ~/.tmux.conf.
sess=$(tmux display-message -p '#{session_name}')

target=$(tmux list-windows -t "$sess" -F '#{window_index} #{@claude_state}' | awk '
  $2 == "needs" && n == "" { n = $1 }
  $2 == "done"  && d == "" { d = $1 }
  END { if (n != "") print n; else if (d != "") print d }
')

if [ -n "$target" ]; then
  tmux select-window -t "$sess:$target"
else
  tmux display-message "✓ No session needs you or is finished — all busy"
fi
