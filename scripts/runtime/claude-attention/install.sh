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

# 4. cwclean zsh function (append once)
if ! grep -q 'cwclean()' "$HOME/.zshrc" 2>/dev/null; then
  printf '\n' >> "$HOME/.zshrc"; cat "$DIR/cwclean.zsh" >> "$HOME/.zshrc"
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
