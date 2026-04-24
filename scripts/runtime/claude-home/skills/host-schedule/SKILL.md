---
name: host-schedule
description: Schedule one-off or recurring cron-style commands from always-on-claude container coding sessions through the host scheduling bridge. Use when the user asks to run something later, overnight, after hours, at a specific time, or on a repeated cron cadence from a container session without direct host cron or at access.
disable-model-invocation: true
---

# Host Schedule

Schedule commands through the always-on-claude host bridge. The host validates requests, submits them to `atd`, and later runs the command back inside the `claude-dev` container.

## Commands

Use the repo-managed CLI:

```bash
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh
```

Common operations:

```bash
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh at "now + 2 hours" -- "npm test"
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh cron "0 3 * * *" -- "npm test"
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh at "03:00 tomorrow" --cwd /home/dev/projects/app -- ./scripts/nightly.sh
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh list
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh status <job-id>
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh logs <job-id>
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh cancel <job-id>
```

## Rules

- Prefer `/host-schedule` for this workflow. `/schedule` may resolve to Claude's built-in scheduling feature.
- Use `cron "<minute> <hour> <day-of-month> <month> <day-of-week>" -- <command>` for recurring jobs.
- Use the current working directory when it is under `/home/dev/projects`; otherwise pass `--cwd /home/dev/projects/<repo>`.
- Do not call host `at`, `atrm`, `crontab`, `systemctl`, or Docker directly from inside the container for this workflow.
- If the bridge inbox is missing, tell the user to run `/update` in the manager session and restart the container so the schedule mounts are available.
- Confirm before scheduling destructive, externally visible, cloud-costing, or production-impacting commands.
