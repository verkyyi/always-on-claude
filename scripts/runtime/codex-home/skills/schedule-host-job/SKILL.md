---
name: schedule-host-job
description: Schedule one-off or recurring cron-style commands from always-on-claude container coding sessions through the host scheduling bridge. Use when the user asks Codex to run something later, overnight, "at" a time, after hours, on a repeated cron cadence, or when a container session needs host-managed scheduling without direct host shell access.
---

# Schedule Host Job

Use the always-on-claude schedule bridge to submit commands from the container to the host. The host validates requests, submits them to `atd`, and later runs the command inside the `claude-dev` container with `docker compose exec`.

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

## Workflow

1. Use the current working directory when it is under `/home/dev/projects`.
2. If the current directory is not under `/home/dev/projects`, pass `--cwd /home/dev/projects/<repo>` or ask which repo should own the job.
3. Submit one-off jobs with `at <time-spec> -- <command>`, or recurring jobs with `cron "<five-field-spec>" -- <command>`.
4. Report the returned job id plus the exact `status` and `logs` commands.
5. Use `list`, `status`, and `logs` instead of inspecting host `atq` directly.

## Safety

- Do not mount the Docker socket or SSH back to the host to schedule jobs.
- Do not run host `at`, `atrm`, `crontab`, `systemctl`, or Docker directly from a container coding session for this workflow.
- Confirm before scheduling destructive, externally visible, cloud-costing, or production-impacting commands.
- If the CLI says the bridge inbox is missing, tell the user to run `/update` in the manager session and restart the container so the schedule mounts are available.
