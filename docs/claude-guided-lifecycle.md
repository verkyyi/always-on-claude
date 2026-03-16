# Claude-Guided Lifecycle (Coming Soon)

## Vision

The full workspace lifecycle — provision, setup, update, destroy — should be Claude Code-guided first, with shell scripts as fallback. Users run slash commands and Claude orchestrates everything.

## Slash commands

| Action | Command | Script fallback |
|---|---|---|
| **Provision** | `/provision` | `provision.sh` |
| **Auth setup** | Claude walks through it | `setup-auth.sh` |
| **Plan overnight work** | `/plan-overnight` | Edit task files manually |
| **Destroy** | `/destroy` | `destroy.sh` |

## How to install (preview)

```bash
mkdir -p ~/.claude/commands
curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/commands/provision.md -o ~/.claude/commands/provision.md
curl -fsSL https://raw.githubusercontent.com/verkyyi/always-on-claude/main/commands/destroy.md -o ~/.claude/commands/destroy.md
```

Then in Claude Code: type `/provision` and Claude orchestrates the entire AWS setup.

## Advantages over scripts

- **Conversational** — asks only what it needs, skips what's obvious
- **Error recovery** — diagnoses and fixes issues mid-flight
- **Adaptive** — detects existing resources, suggests reuse
- **No memorizing env vars** — just describe what you want

## Status

Slash commands exist and work but are still being refined. The script fallbacks are the stable path for now.
