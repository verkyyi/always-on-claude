# Schedule Host Job

Schedule commands from this container coding session through the always-on-claude host scheduling bridge.

Note: Claude Code may reserve `/schedule` for its built-in scheduling feature. If this command is not shown, use `/host-schedule`, which is the non-conflicting user-scope skill for this bridge.

## Context

- Arguments: $ARGUMENTS
- Current directory: !`pwd`
- Bridge status: !`test -d /home/dev/.aoc/schedule/inbox && test -w /home/dev/.aoc/schedule/inbox && echo ready || echo unavailable`

## Usage

Use this repo-managed CLI for all operations:

```bash
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh
```

Parse `$ARGUMENTS` as one of:

- Empty or `list`: show scheduled jobs.
- `at <time spec> -- <command>`: schedule a one-off command from the current project directory.
- `cron <5-field spec> -- <command>`: schedule a recurring command from the current project directory.
- `at <time spec> --cwd <path> -- <command>`: schedule from an explicit container path under `/home/dev/projects`.
- `status <job-id>`: show status JSON.
- `logs <job-id> [lines]`: show recent logs.
- `cancel <job-id>`: request cancellation of a queued host `at` job.

Examples:

```bash
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh at "now + 2 hours" -- "npm test"
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh cron "0 3 * * *" -- "npm test"
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh at "03:00 tomorrow" -- ./scripts/nightly.sh
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh list
```

## Rules

- Do not call host `at`, `atrm`, `crontab`, `systemctl`, or Docker directly for this workflow from inside the container.
- If the bridge is unavailable, tell the user to run `/update` from the manager session and restart the container so the schedule mounts are present.
- Confirm before scheduling destructive, externally visible, cloud-costing, or long-running production actions.
- Keep output compact: return the job id, status command, and logs command.
