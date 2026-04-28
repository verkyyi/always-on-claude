---
name: schedule-host-job
description: Schedule one-off or recurring local-time commands from always-on-claude container coding sessions through the host-native v2 scheduler. Use when the user asks Codex to run something later, overnight, at a specific local time, after hours, or on an hourly/daily/weekly/monthly cadence from a container session without direct host scheduler access.
---

# Schedule Host Job

Use the always-on-claude v2 scheduler to submit commands from the container to the host. The host validates requests, installs native scheduler entries, and later runs the command inside the `claude-dev` container with `docker compose exec`.

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

## Workflow

1. Use the current working directory when it is under `/home/dev/projects`.
2. If the current directory is not under `/home/dev/projects`, pass `--cwd /home/dev/projects/<repo>` or ask which repo should own the job.
3. Submit one-off jobs with `at "YYYY-MM-DD HH:MM" -- <command>`, or recurring jobs with `hourly`, `daily`, `weekly`, or `monthly`.
4. Report the returned job id plus the exact `status` and `logs` commands.
5. Use `list`, `status`, and `logs` instead of inspecting host scheduler state directly.

## Safety

- Do not mount the Docker socket or SSH back to the host to schedule jobs.
- Do not run host `launchctl`, `systemctl`, `crontab`, or Docker directly from a container coding session for this workflow.
- Confirm before scheduling destructive, externally visible, cloud-costing, or production-impacting commands.
- If the CLI says the v2 inbox is missing, tell the user to run `/update` in the manager session and restart the container so the schedule mounts are available.
