# Schedule Host Job

Schedule commands from this container coding session through the always-on-claude host-native v2 scheduler.

Note: Claude Code may reserve `/schedule` for its built-in scheduling feature. If this command is not shown, use `/host-schedule`, which is the non-conflicting user-scope skill for this bridge.

## Context

- Arguments: $ARGUMENTS
- Current directory: !`pwd`
- Scheduler status: !`test -d /home/dev/.always-on-claude/schedule/inbox-v2 && test -w /home/dev/.always-on-claude/schedule/inbox-v2 && echo ready || echo unavailable`

## Usage

Use this repo-managed CLI for all operations:

```bash
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh
```

Parse `$ARGUMENTS` as one of:

- Empty or `list`: show scheduled jobs.
- `at <YYYY-MM-DD HH:MM> -- <command>`: schedule a one-off command in host local time.
- `hourly --minute <0-59> -- <command>`: schedule an hourly recurring command.
- `daily --time <HH:MM> -- <command>`: schedule a daily recurring command.
- `weekly --weekday <weekday> --time <HH:MM> -- <command>`: schedule a weekly recurring command.
- `monthly --day <1-31> --time <HH:MM> -- <command>`: schedule a monthly recurring command.
- `... --cwd <path> -- <command>`: schedule from an explicit container path under `/home/dev/projects`.
- `health`: show bridge health JSON.
- `status <job-id>`: show status JSON.
- `logs <job-id> [lines]`: show recent logs.
- `delete <job-id>`: remove a scheduled job.
- `enable <job-id>` / `disable <job-id>`: toggle a job.
- `run-now <job-id>`: request an immediate run of the current slot.

Examples:

```bash
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh at "2026-04-26 09:00" -- "npm test"
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh daily --time 03:00 -- ./scripts/nightly.sh
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh hourly --minute 0 -- ./scripts/hourly.sh
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh list
```

## Rules

- Do not call host `launchctl`, `systemctl`, `crontab`, or Docker directly for this workflow from inside the container.
- If the scheduler is unavailable, tell the user to run `/update` from the manager session and restart the container so the schedule mounts are present.
- Confirm before scheduling destructive, externally visible, cloud-costing, or long-running production actions.
- Keep output compact: return the job id, status command, and logs command.
