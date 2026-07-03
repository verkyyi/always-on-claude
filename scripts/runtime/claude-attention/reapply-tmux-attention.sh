#!/bin/sh
# reapply-tmux-attention.sh — ensure ~/.tmux.conf sources the Claude attention layer.
# Run this after any host re-provisioning that regenerates ~/.tmux.conf.
# Idempotent: does nothing if the source line is already present.
CONF="$HOME/.tmux.conf"
LINE="if-shell '[ -f ~/.claude/tmux-attention.conf ]' 'source-file ~/.claude/tmux-attention.conf'"

[ -f "$CONF" ] || : > "$CONF"
if grep -qF 'tmux-attention.conf' "$CONF"; then
  echo "already present in $CONF"
else
  { echo ""; echo "# --- Claude session attention layer (reapplied) ---"; echo "$LINE"; } >> "$CONF"
  echo "appended source line to $CONF"
fi
tmux source-file "$CONF" 2>/dev/null && echo "reloaded" || echo "(tmux not running; will apply on next start)"
