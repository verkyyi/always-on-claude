---
name: host-schedule
description: Schedule one-off or recurring local-time commands from always-on-claude container coding sessions through the host-native v2 scheduler. Use when the user asks to run something later, overnight, after hours, at a specific local time, or on an hourly/daily/weekly/monthly cadence from a container session without direct host scheduler access.
disable-model-invocation: true
---

# Host Schedule

Schedule commands through the always-on-claude host-native v2 scheduler. The host validates requests, installs native schedule entries, and later runs the command back inside the `claude-dev` container.

## Commands

Use the repo-managed CLI:

```bash
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh
```

Common operations:

```bash
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh at "2026-04-26 09:00" -- "npm test"
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh daily --time 03:00 -- ./scripts/nightly.sh
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh hourly --minute 0 -- ./scripts/hourly.sh
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh weekly --weekday friday --time 21:00 -- ./scripts/report.sh
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh list
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh status <job-id>
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh logs <job-id>
/home/dev/dev-env/scripts/runtime/aoc-schedule.sh delete <job-id>
```

## Rules

- Prefer `/host-schedule` for this workflow. `/schedule` may resolve to Claude's built-in scheduling feature.
- Use `hourly`, `daily`, `weekly`, or `monthly` for recurring jobs.
- Use the current working directory when it is under `/home/dev/projects`; otherwise pass `--cwd /home/dev/projects/<repo>`.
- Do not call host `launchctl`, `systemctl`, `crontab`, or Docker directly from inside the container for this workflow.
- If the v2 inbox is missing, tell the user to run `/update` in the manager session and restart the container so the schedule mounts are available.
- Confirm before scheduling destructive, externally visible, cloud-costing, or production-impacting commands.
