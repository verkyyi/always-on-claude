#!/bin/sh
# set-claude-state.sh <state> [bell]
# Stamps the current tmux window's @claude_state (semantic: working|done|needs).
# The ~/.claude/tmux-spinner.sh daemon reads @claude_state and renders ALL the
# visuals (spinner glyph + its pulsing font color + name color) via @spin, so
# this hook only sets the semantic state and (for needs) rings the bell.
# Always exits 0 so it never blocks a turn.
[ -n "$TMUX" ] || exit 0
[ -n "$TMUX_PANE" ] || exit 0

case "$1" in
  needs) sem="needs" ;;
  done)  sem="done" ;;
  *)     sem="working" ;;   # busy / between-tools / prompt submitted
esac

tmux set-window-option -t "$TMUX_PANE" @claude_state "$sem" 2>/dev/null

[ "${2:-}" = "bell" ] && printf '\a' > /dev/tty 2>/dev/null

exit 0
