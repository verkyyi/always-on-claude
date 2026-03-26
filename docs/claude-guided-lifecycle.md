# Claude-Guided Lifecycle

## Vision

The full workspace lifecycle — provision, setup, update, destroy — is Claude Code-guided first, with shell scripts as fallback. Users run slash commands and Claude orchestrates everything.

## Slash commands

| Action | Command | Script fallback |
|---|---|---|
| **Provision** | `/provision` | `provision.sh` |
| **Auth setup** | Claude walks through it | `setup-auth.sh` |
| **Update** | `/update` | `self-update.sh` |
| **Destroy** | `/destroy` | `destroy.sh` |
| **Tailscale** | `/tailscale` | manual setup |
| **Workspace** | `/workspace` | `worktree-helper.sh` |

## Mobile-friendly commands

Short aliases for phone use:

| Command | Does |
|---|---|
| `/s` | Status: git state, PRs, instance health |
| `/d` | Deploy current project |
| `/l` | Show recent logs |
| `/fix` | Fix failing tests and commit |
| `/ship` | Merge PR, deploy, verify health |
| `/review` | Summarize open PRs, approve/merge |

## How it works

Slash commands live in `.claude/commands/` and are auto-discovered by Claude Code when running in this repo. No manual installation needed — just clone the repo and run `claude`.

## Advantages over scripts

- **Conversational** — asks only what it needs, skips what's obvious
- **Error recovery** — diagnoses and fixes issues mid-flight
- **Adaptive** — detects existing resources, suggests reuse
- **No memorizing env vars** — just describe what you want
