#!/bin/bash
# classify-sessions.sh — reconcile hook-derived @claude_state with reality using
# `claude -p` (haiku). Hooks are fast but semantically blind: a Stop between loop
# iterations looks like "done"/"needs" when the session is really LOOPING. This
# reads the pane and recovers the true intent for QUIET windows only.
#
# Cost gating (lazy):
#   * ONLY classifies windows whose state is done|needs|looping (ambiguous/quiet).
#     'working' windows are skipped entirely -> the heartbeat already knows them.
#   * Change-detected: a window is only sent to the LLM when its pane content
#     changed since last check. A loop paused between iterations has a static
#     screen -> classified once, then skipped -> steady-state cost ~= 0.
#   * Caps classifications per tick.
# Run from launchd (com.verkyyi.classify-sessions, StartInterval 60).
set -u
CACHE="$HOME/.claude/.classify-cache"; mkdir -p "$CACHE"
LOG="$HOME/.claude/classify-sessions.log"
MODEL="${CLASSIFY_MODEL:-haiku}"
MAXW="${CLASSIFY_MAX:-8}"

command -v claude >/dev/null 2>&1 || exit 0
tmux info >/dev/null 2>&1 || exit 0

RUBRIC='You are a status classifier for a Claude Code terminal session. Based ONLY on the terminal screen below, reply with EXACTLY ONE word and nothing else:
WORKING - Claude is actively generating or a tool is running (e.g. shows "esc to interrupt", a live spinner, streaming output).
WAITING - Claude asked the user a question or is blocked waiting for input / confirmation.
LOOPING - idle right now but a scheduled wakeup or next loop iteration is pending (mentions waiting N seconds, scheduled, will continue, /loop).
STOPPED - finished; idle with nothing pending.
ERROR - a crash or error state.
Screen:
-----'

n=0
tmux list-windows -a -F '#{session_name}:#{window_index} #{@claude_state}' | while read -r win st; do
  case "$st" in
    done|needs|looping) : ;;   # quiet/ambiguous -> candidate
    *) continue ;;             # working / empty -> skip (free)
  esac
  [ "$n" -ge "$MAXW" ] && continue

  cap=$(tmux capture-pane -p -t "$win" 2>/dev/null | sed '/^[[:space:]]*$/d' | tail -35)
  [ -z "$cap" ] && continue

  h=$(printf '%s' "$cap" | cksum | awk '{print $1}')
  hf="$CACHE/$(printf '%s' "$win" | tr '/:' '__').hash"
  [ "$h" = "$(cat "$hf" 2>/dev/null)" ] && continue    # unchanged screen -> no LLM call

  raw=$(printf '%s\n%s\n' "$RUBRIC" "$cap" | claude -p --model "$MODEL" 2>/dev/null)
  label=$(printf '%s' "$raw" | tr -d '[:space:].' | tr '[:lower:]' '[:upper:]')
  echo "$h" > "$hf"     # remember we've seen this screen regardless of parse

  case "$label" in
    *WAITING*) new="needs" ;;
    *LOOPING*) new="looping" ;;
    *STOPPED*) new="done" ;;
    *ERROR*)   new="needs" ;;
    *WORKING*) new="working" ;;
    *) printf '%s  %-10s unparsed [%s]\n' "$(date +%H:%M:%S)" "$win" "${raw:0:40}" >> "$LOG"; n=$((n+1)); continue ;;
  esac

  if [ "$new" != "$st" ]; then
    tmux set-window-option -t "$win" @claude_state "$new" 2>/dev/null
    printf '%s  %-10s %-8s -> %s\n' "$(date +%H:%M:%S)" "$win" "$st" "$new" >> "$LOG"
  fi
  n=$((n + 1))
done

[ -f "$LOG" ] && { tail -n 300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; }
exit 0
