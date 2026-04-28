#!/bin/bash
# macmini-apply-network-tuning.sh — Keep a wider host IPv4 ephemeral port range on macOS.

set -euo pipefail

FIRST="${AOC_HOST_PORTRANGE_FIRST:-32768}"
HIFIRST="${AOC_HOST_PORTRANGE_HIFIRST:-32768}"

sudo sysctl -w "net.inet.ip.portrange.first=$FIRST" >/dev/null
sudo sysctl -w "net.inet.ip.portrange.hifirst=$HIFIRST" >/dev/null

printf 'Applied host IPv4 port range tuning: first=%s hifirst=%s\n' "$FIRST" "$HIFIRST"
sysctl net.inet.ip.portrange.first net.inet.ip.portrange.hifirst

