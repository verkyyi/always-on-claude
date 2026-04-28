# Local-Time Native Scheduler Design

## Goal

Replace the current macOS/Linux schedule bridge execution model with a simpler design:

- Host local time is authoritative.
- Native host schedulers handle normal recurring execution.
- A small host recovery controller handles missed-run catch-up.
- Jobs still execute inside the existing `dev` container.
- The container never receives broad host-control privileges.

This design explicitly drops UTC-based due gating. Schedules are defined in host local time only.

## Scope

In scope:

- Recurring jobs scheduled in host local time
- One-off jobs scheduled in host local time
- Missed-run catch-up after host/service downtime
- Status/log persistence under `~/.always-on-claude/schedule/`
- macOS implementation via `launchd`
- Linux implementation via `systemd`

Out of scope:

- Timezone-aware business logic inside job payloads
- Full cron parser parity on macOS
- Multi-user schedule isolation

## Design Principles

1. The host owns scheduling.
2. The container owns workload logic.
3. Normal execution should use native schedulers directly.
4. Catch-up should be explicit and slot-based.
5. Every run should be attributable to one intended schedule slot.
6. Duplicate execution of the same slot is forbidden.

## Terminology

- **Job**: named scheduled workload definition
- **Slot**: intended occurrence of a job in host local time
- **Scheduled run**: normal native scheduler invocation for a slot
- **Catch-up run**: late invocation for a missed slot that is still within grace
- **Grace window**: how long a missed slot remains eligible for catch-up

Examples of slot keys:

- Daily at `03:00`: `2026-04-25T03:00`
- Hourly at `:00`: `2026-04-25T11:00`
- Weekly Friday `21:00`: `2026-04-24T21:00`

Slot keys are always interpreted in the host timezone and persisted as local wall-clock values plus timezone metadata.

## Schedule Semantics

### Source of truth

- The host timezone is authoritative.
- Schedule metadata stores the timezone string used at creation time, e.g. `America/Los_Angeles`.
- The host scheduler decides when the job should fire.

### Normal execution

- Native scheduler runs the job at the expected host-local time.

### Catch-up execution

- If the scheduled slot was missed while the host or scheduler was unavailable, the recovery controller may run it once after recovery.
- Catch-up is allowed only if the missed slot is still within the configured grace window.

### Duplicate prevention

- A slot that has already completed must never run again.
- A slot already running must not start again.

## Supported Schedule Forms

Initial v2 supported recurring schedule forms:

- Hourly at minute `MM`
- Daily at `HH:MM`
- Weekly on weekday at `HH:MM`
- Monthly on day `DD` at `HH:MM`

Initial v2 one-off schedule form:

- One explicit local timestamp: `YYYY-MM-DD HH:MM`

Rationale:

- These forms map cleanly to both `launchd` and `systemd`.
- They keep the macOS implementation native without recreating a cron engine.

Cron syntax may remain accepted at the CLI layer only if it translates into the supported subset. Unsupported expressions must fail fast with a clear error.

## File Layout

All schedule state lives under:

```text
~/.always-on-claude/schedule/
```

Subdirectories/files:

```text
schedule/
  jobs/
    <job-id>.json
    <job-id>.sh
  status/
    <job-id>.json
  logs/
    <job-id>.log
    recovery.log
  runs/
    <job-id>/
      <slot-key>.json
  native/
    macos/
      com.always-on-claude.schedule.<job-id>.plist
      com.always-on-claude.schedule-recovery.plist
    linux/
      always-on-claude-schedule-<job-id>.service
      always-on-claude-schedule-<job-id>.timer
      always-on-claude-schedule-recovery.service
      always-on-claude-schedule-recovery.timer
  bridge-health.json
```

Notes:

- `jobs/<job-id>.json` is the canonical job definition.
- `status/<job-id>.json` is the current summarized state.
- `runs/<job-id>/<slot-key>.json` is the immutable per-slot ledger.
- `native/` contains generated scheduler definitions for debugging and reconciliation.

## Job Definition Schema

Example:

```json
{
  "version": 2,
  "id": "dashboard-hourly",
  "label": "dashboard-hourly-due",
  "timezone": "America/Los_Angeles",
  "schedule": {
    "type": "hourly",
    "minute": 0
  },
  "grace_window_sec": 7200,
  "cwd": "/home/dev/projects/dashboard",
  "command": "python3 dashboard/hourly.sh",
  "container_service": "dev",
  "compose_file": "docker-compose.macmini.yml",
  "created_at": "2026-04-25T11:30:00-07:00",
  "requested_by": "dev",
  "enabled": true
}
```

Allowed `schedule` forms:

- Hourly:

```json
{"type":"hourly","minute":0}
```

- Daily:

```json
{"type":"daily","hour":3,"minute":0}
```

- Weekly:

```json
{"type":"weekly","weekday":"friday","hour":21,"minute":0}
```

- Monthly:

```json
{"type":"monthly","day":1,"hour":9,"minute":30}
```

- One-off:

```json
{"type":"once","local_time":"2026-04-26 09:00"}
```

## Status Schema

Example:

```json
{
  "id": "dashboard-hourly",
  "label": "dashboard-hourly-due",
  "timezone": "America/Los_Angeles",
  "status": "scheduled",
  "current_slot": null,
  "last_started_at": "2026-04-25T11:00:02-07:00",
  "last_finished_at": "2026-04-25T11:00:45-07:00",
  "last_started_slot": "2026-04-25T11:00",
  "last_finished_slot": "2026-04-25T11:00",
  "last_successful_slot": "2026-04-25T11:00",
  "last_run_mode": "scheduled",
  "last_run_status": "succeeded",
  "last_exit_code": 0,
  "updated_at": "2026-04-25T11:00:45-07:00",
  "log_file": "/Users/verkyyi/.always-on-claude/schedule/logs/dashboard-hourly.log"
}
```

Allowed `status` values:

- `scheduled`
- `running`
- `succeeded`
- `failed`
- `canceled`
- `disabled`

## Per-Slot Ledger Schema

Each attempted slot gets a ledger entry:

```json
{
  "job_id": "dashboard-hourly",
  "slot": "2026-04-25T11:00",
  "timezone": "America/Los_Angeles",
  "run_mode": "scheduled",
  "started_at": "2026-04-25T11:00:02-07:00",
  "finished_at": "2026-04-25T11:00:45-07:00",
  "status": "succeeded",
  "exit_code": 0
}
```

This ledger is the dedupe source of truth. Status JSON is only a summary.

## CLI Surface

The container-facing CLI remains:

```bash
aoc-schedule at ...
aoc-schedule hourly ...
aoc-schedule daily ...
aoc-schedule weekly ...
aoc-schedule monthly ...
aoc-schedule list
aoc-schedule status <job-id>
aoc-schedule logs <job-id>
aoc-schedule cancel <job-id>
aoc-schedule health
```

Recommended new forms:

```bash
aoc-schedule hourly --minute 0 -- "python3 dashboard/hourly.sh"
aoc-schedule daily --time 03:00 -- "python3 scripts/daily_brief/brief.py am"
aoc-schedule daily --time 15:30 -- "python3 scripts/daily_brief/brief.py pm"
aoc-schedule weekly --weekday friday --time 21:00 -- "./weekly.sh"
aoc-schedule at "2026-04-26 09:00" -- "./once.sh"
```

`list` should show host-local times and timezone explicitly.

## Host Control Plane

The host control plane is responsible for:

- validating job requests
- writing job metadata
- generating runner scripts
- generating native scheduler definitions
- loading/unloading native scheduler entries
- updating status and slot ledger files

The control plane may continue to accept requests from the container through a narrow bridge, but the bridge should no longer be the runtime job executor.

## Job Runner Contract

The generated runner script must support:

```bash
<job-id>.sh --slot <slot-key> --mode scheduled
<job-id>.sh --slot <slot-key> --mode catchup
```

Runner steps:

1. Load job definition.
2. Acquire a per-job lock.
3. Check slot ledger for `<slot-key>`.
4. If slot already completed, exit `0` as duplicate/no-op.
5. Create or update the slot ledger with `running`.
6. Update job status summary to `running`.
7. Execute:

```bash
docker compose -f <compose-file> exec -T -w <cwd> <service> bash -lc <command>
```

8. Write final slot ledger state.
9. Update job status summary.
10. Release lock.

The runner may enforce a per-job timeout.

## Native Scheduling: macOS

### Normal recurring runs

Each job gets its own LaunchAgent plist:

- label: `com.always-on-claude.schedule.<job-id>`
- program: `/bin/bash <job-script> --slot <current-slot> --mode scheduled`

Because `launchd` cannot compute slot keys itself, the LaunchAgent should call a small wrapper:

```bash
/bin/bash /path/to/run-scheduled-job.sh <job-id>
```

That wrapper computes the expected current slot for the job definition, then invokes the generated runner.

The plist uses `StartCalendarInterval`.

Example mappings:

- Hourly at minute 0:

```xml
<key>StartCalendarInterval</key>
<dict>
  <key>Minute</key><integer>0</integer>
</dict>
```

- Daily at `03:00`:

```xml
<key>StartCalendarInterval</key>
<dict>
  <key>Hour</key><integer>3</integer>
  <key>Minute</key><integer>0</integer>
</dict>
```

- Weekly Friday `21:00`:

```xml
<key>StartCalendarInterval</key>
<dict>
  <key>Weekday</key><integer>6</integer>
  <key>Hour</key><integer>21</integer>
  <key>Minute</key><integer>0</integer>
</dict>
```

### Recovery controller

One separate LaunchAgent:

- label: `com.always-on-claude.schedule-recovery`
- `RunAtLoad = true`
- `StartInterval = 60`

Responsibilities:

- inspect all enabled jobs
- compute the latest missed slot in host local time
- compare against slot ledger
- trigger catch-up for slots still within grace

This controller is not the primary recurring scheduler. It is only for recovery.

### macOS constraints

- Do not use `WatchPaths`.
- Do not rely on detached shell children from a oneshot LaunchAgent.
- Do not daemonize.
- Let `launchd` own the process lifecycle of each normal scheduled job.

## Native Scheduling: Linux

### Normal recurring runs

Each job gets:

- `always-on-claude-schedule-<job-id>.service`
- `always-on-claude-schedule-<job-id>.timer`

The timer uses `OnCalendar=` and `Persistent=true`.

Example:

```ini
[Unit]
Description=Always-on-claude schedule dashboard-hourly

[Timer]
OnCalendar=*-*-* *:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

The matching service runs:

```ini
[Service]
Type=oneshot
ExecStart=/bin/bash /home/dev/.always-on-claude/schedule/jobs/dashboard-hourly.sh --slot %%slot%% --mode scheduled
```

As with macOS, a small wrapper should compute the exact slot key before invoking the runner.

### Recovery controller

Linux may omit a custom recovery controller if `Persistent=true` is sufficient.

For parity and clearer status handling, v2 may still include a lightweight recovery service/timer:

- `RunAtBootSec=1min`
- `OnUnitActiveSec=60`

Responsibilities match macOS recovery, but Linux should prefer native timer persistence where possible.

## Slot Computation Rules

Slot computation must be centralized in one helper script/library.

For a given job definition and current local time:

- Hourly:
  - slot is current hour at configured minute, or previous hour if current minute is earlier
- Daily:
  - slot is today at configured time, or yesterday if not yet reached
- Weekly:
  - slot is most recent configured weekday/time
- Monthly:
  - slot is most recent configured day/time
- Once:
  - slot is the explicit scheduled local time

The recovery controller should only consider the most recent eligible slot.

## Catch-Up Rules

For each job:

1. Compute the latest intended slot in host local time.
2. Check whether that slot exists in the slot ledger as completed.
3. If not completed and not currently running:
   - if now minus slot time <= grace window, run catch-up
   - otherwise mark missed and do not run

Missed slots outside grace should be recorded in the slot ledger as:

```json
{
  "job_id": "daily-brief-am",
  "slot": "2026-04-25T03:00",
  "timezone": "America/Los_Angeles",
  "run_mode": "catchup",
  "status": "missed",
  "reason": "outside grace window"
}
```

## Cancellation

Canceling a job must:

- disable or unload the native scheduler definition
- prevent future scheduled runs
- optionally stop an in-flight run
- preserve history files

One-off jobs should be removed from native scheduler state after completion or cancellation.

## Logging

Per-job logs remain:

```text
~/.always-on-claude/schedule/logs/<job-id>.log
```

Recovery controller log:

```text
~/.always-on-claude/schedule/logs/recovery.log
```

Each run should log:

- slot key
- mode (`scheduled` or `catchup`)
- start timestamp
- command
- final exit code

## Health

`bridge-health.json` should become `scheduler-health.json` in v2 semantics, but the CLI may continue reading `bridge-health.json` for compatibility.

Suggested fields:

```json
{
  "state": "idle",
  "timezone": "America/Los_Angeles",
  "last_recovery_check_at": "2026-04-25T11:00:00-07:00",
  "active_jobs": 1,
  "enabled_jobs": 4
}
```

## Migration Plan

### Phase 1: dual-write foundations

- Add v2 job metadata schema
- Add slot ledger
- Add runner that accepts explicit slot/mode
- Keep existing bridge CLI shape

### Phase 2: native scheduler install

- Add macOS plist generator
- Add Linux systemd unit generator
- Install native scheduled jobs for new schedules only

### Phase 3: recovery controller

- Implement macOS recovery LaunchAgent
- Implement Linux recovery service/timer if retained

### Phase 4: migrate existing jobs

- Read existing v1 status files
- Convert into v2 job definitions
- Reinstall as native jobs
- Preserve old logs/status for history

### Phase 5: remove v1 execution path

- Stop using `process-schedule-requests.sh` as runtime executor
- Remove `WatchPaths`-based runtime behavior
- Keep only narrow request handling if still needed for container-to-host submission

## Open Questions

1. Should the CLI surface only the new structured schedule forms, or keep a cron-compatible facade?
2. Should catch-up record `missed` slots explicitly, or only record attempted slots?
3. On macOS, should one-off jobs use generated one-shot plists or a small controller queue?
4. Should timezone changes after job creation rewrite schedules automatically, or require re-save?

## Recommendation

Implement v2 with:

- host-local schedule semantics only
- structured schedule forms first
- native scheduling for normal execution
- explicit slot ledger for dedupe and catch-up
- small recovery controller for macOS
- `systemd` timer persistence on Linux

This gives a simpler, more platform-correct design than the current poll-and-dispatch bridge while preserving the security boundary that motivated the original architecture.
