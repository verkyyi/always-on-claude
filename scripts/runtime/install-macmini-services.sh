#!/bin/bash
# install-macmini-services.sh — Install Mac mini host services.

set -euo pipefail

REPO="${AOC_REPO:-$HOME/always-on-claude}"

bash "$REPO/scripts/runtime/install-macmini-host-tools.sh"
bash "$REPO/scripts/runtime/install-macmini-schedule-bridge.sh"
bash "$REPO/scripts/runtime/install-macmini-nginx.sh"
