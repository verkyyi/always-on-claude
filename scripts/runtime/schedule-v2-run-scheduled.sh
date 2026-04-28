#!/bin/bash
# schedule-v2-run-scheduled.sh — Compute the current slot and run one job in scheduled mode.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/schedule-v2-lib.sh"

job_id="${1:-}"
[[ -n "$job_id" ]] || schedule_v2_die "Usage: schedule-v2-run-scheduled.sh <job-id>"

schedule_v2_ensure_dirs
schedule_v2_load_job "$job_id"

slot="$(schedule_v2_compute_slot "$SCHEDULE_V2_JOB_FILE")"
exec "$SCRIPT_DIR/schedule-v2-runner.sh" --job-id "$job_id" --slot "$slot" --mode scheduled
