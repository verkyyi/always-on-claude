#!/bin/bash
# install-macmini-agent-upgrade-schedule.sh — Schedule daily container agent upgrades on the Mac mini.

set -euo pipefail

REPO="${AOC_REPO:-$HOME/always-on-claude}"
SCHEDULE="${AOC_AGENT_UPGRADE_TIME:-03:00}"
JOB_ID="${AOC_AGENT_UPGRADE_JOB_ID:-agent-upgrades-daily}"
JOB_LABEL="${AOC_AGENT_UPGRADE_LABEL:-agent-upgrades-daily}"
CONTAINER_CWD="${AOC_AGENT_UPGRADE_CWD:-/home/dev/projects}"
COMMAND='mkdir -p ~/.cache/aoc && /home/dev/dev-env/scripts/runtime/upgrade-code-agents.sh | tee ~/.cache/aoc/agent-upgrade.log'
SCHEDULER="$REPO/scripts/runtime/aoc-schedule.sh"

printf '\n=== Agent upgrade schedule ===\n'

if [[ ! -f "$SCHEDULER" ]]; then
    printf 'ERROR: Scheduler not found at %s\n' "$SCHEDULER" >&2
    exit 1
fi

bash "$SCHEDULER" daily \
    --time "$SCHEDULE" \
    --cwd "$CONTAINER_CWD" \
    --label "$JOB_LABEL" \
    --id "$JOB_ID" \
    -- "$COMMAND"

printf '  OK: Scheduled %s at %s\n' "$JOB_ID" "$SCHEDULE"
printf '  OK: Status command: bash %s status %s\n' "$SCHEDULER" "$JOB_ID"

