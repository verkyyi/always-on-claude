# Claude multi-session attention layer

At-a-glance status for many parallel Claude Code sessions running in one tmux
session (`main`), each on a `cw`-created worktree. Tells you which session needs
you without switching windows.

## Install

```sh
scripts/runtime/claude-attention/install.sh
```

Copies scripts to `~/.claude`, plists to `~/Library/LaunchAgents`, merges the
`settings.json` hooks, sources `tmux-attention.conf` from `~/.tmux.conf`, appends
`cwclean` to `~/.zshrc`, and loads the three launchd agents.

## The footer, decoded

| You see | Meaning |
|---|---|
| `⠹` pulsing **cyan** glyph | working (tool activity — flicker ≈ tool cadence) |
| `⠹` pulsing **indigo** glyph | looping (auto-resuming; leave it) |
| `✓` **green** | done / stopped |
| `!` **red font** | needs your answer (+ terminal bell) |
| light **block** (non-blue) | the window you're currently in |

Window numbers are contiguous and match display order (`base-index 1`,
`renumber-windows on`) so `prefix + N` = the Nth window you see.

## How it works — three tiers

1. **Hooks** (`hooks/set-claude-state.sh`, wired via `settings.hooks.json`):
   `PreToolUse`/`PostToolUse` → working flicker; `Stop` → done; `Notification`
   → needs + bell. Instant, free. Also `hooks/guard.py` = `PreToolUse` deny-list
   blocking force-push-to-master / prod-RDS writes / prod `kubectl` deletes /
   `rm -rf` on root|home|.git (insurance under `bypassPermissions`).
2. **Spinner daemon** (`tmux-spinner.sh`, launchd `com.verkyyi.tmux-spinner`):
   animates the glyph; one coalesced repaint per frame; zero cost on idle windows.
3. **LLM classifier** (`classify-sessions.sh`, launchd `com.verkyyi.classify-sessions`,
   60s): reads quiet panes with `claude -p --model haiku` to recover true intent
   (looping vs stopped vs waiting) that hooks can't see. Change-gated → ~cents/day.

## Keybindings (prefix = `C-a`)

- `prefix + a` — jump to the next session that needs you
- `prefix + j` — fzf session picker (state · branch · ahead/behind · dirty · live preview)
- `prefix + i` — open PRs/issues glance; Enter prints a cmd-clickable URL (SSH/iTerm)
- `prefix + r` — reload tmux config

## Housekeeping

- `cwclean [--prune]` (zsh) + `worktree-autoclean.sh` (launchd
  `com.verkyyi.worktree-autoclean`, hourly): prune merged + unattached worktrees.

## Control

```sh
launchctl unload ~/Library/LaunchAgents/com.verkyyi.tmux-spinner.plist       # stop animation
launchctl unload ~/Library/LaunchAgents/com.verkyyi.classify-sessions.plist  # stop LLM classifier
launchctl unload ~/Library/LaunchAgents/com.verkyyi.worktree-autoclean.plist # stop janitor
```

Tunables: `SPIN_INTERVAL` (spinner fps) and classifier `StartInterval` in the
plists; guard rules in `hooks/guard.py`. Logs: `~/.claude/classify-sessions.log`,
`~/.claude/worktree-autoclean.log`.

## Persistence

Everything lives in `~/.claude` (which `aoc-update` does not regenerate).
`tmux-attention.conf` is sourced by one `if-shell` line in `~/.tmux.conf`;
`reapply-tmux-attention.sh` restores that line if the host is re-provisioned.
