#!/bin/bash
# process-all-schedule-requests.sh — Run both legacy and v2 schedule processors.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

"$SCRIPT_DIR/process-schedule-requests.sh" "$@"
"$SCRIPT_DIR/process-schedule-v2-requests.sh"

