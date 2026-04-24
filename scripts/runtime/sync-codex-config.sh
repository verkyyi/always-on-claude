#!/bin/bash
# sync-codex-config.sh — Ensure Codex defaults are present in ~/.codex/config.toml.
#
# This workspace is already externally sandboxed, so Codex should default to the
# same low-friction execution model we use operationally on provisioned hosts.

set -euo pipefail

CONFIG_DIR="${CODEX_HOME:-${HOME}/.codex}"
CONFIG_FILE="${CONFIG_DIR}/config.toml"

mkdir -p "$CONFIG_DIR"

tmp=$(mktemp)

if [[ -f "$CONFIG_FILE" ]]; then
    awk '
        BEGIN {
            inserted = 0
            pre_count = 0
        }
        function print_preamble(   i, last_nonempty) {
            last_nonempty = pre_count
            while (last_nonempty > 0 && pre[last_nonempty] ~ /^[[:space:]]*$/) {
                last_nonempty--
            }
            for (i = 1; i <= last_nonempty; i++) {
                print pre[i]
            }
        }
        /^approval_policy[[:space:]]*=/ { next }
        /^sandbox_mode[[:space:]]*=/ { next }
        {
            if (!inserted && $0 ~ /^\[/) {
                print_preamble()
                print "approval_policy = \"never\""
                print "sandbox_mode = \"danger-full-access\""
                print ""
                inserted = 1
                print
                next
            }
            if (!inserted) {
                pre[++pre_count] = $0
            } else {
                print
            }
        }
        END {
            if (!inserted) {
                print_preamble()
                print "approval_policy = \"never\""
                print "sandbox_mode = \"danger-full-access\""
            }
        }
    ' "$CONFIG_FILE" > "$tmp"
else
    cat > "$tmp" <<'EOF'
approval_policy = "never"
sandbox_mode = "danger-full-access"
EOF
fi

if [[ -f "$CONFIG_FILE" ]] && cmp -s "$tmp" "$CONFIG_FILE"; then
    rm -f "$tmp"
    echo "unchanged"
    exit 0
fi

mv "$tmp" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
echo "updated"
