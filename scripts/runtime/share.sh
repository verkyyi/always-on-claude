#!/bin/bash
# share.sh — Manage temporary SSH access for guest collaboration
#
# Subcommands:
#   create [hours]   — generate temp SSH key, add to authorized_keys, output connection info
#   list             — show active temporary access grants
#   revoke [all|id]  — remove specific or all temporary keys
#   cleanup          — remove expired keys (safe to call from cron)
#
# Temporary keys are marked in authorized_keys with:
#   # TEMP_ACCESS expires=<unix_timestamp> id=<uuid> created=<iso_date>

set -euo pipefail

AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
TEMP_KEY_DIR="$HOME/.ssh/temp_keys"
MARKER_PREFIX="# TEMP_ACCESS"
DEFAULT_HOURS=24

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
warn()  { echo "  WARN: $*"; }
die()   { echo "ERROR: $*" >&2; exit 1; }

generate_id() {
    # Short 8-char hex ID for easy reference
    head -c 4 /dev/urandom | xxd -p
}

ensure_dirs() {
    mkdir -p "$TEMP_KEY_DIR"
    chmod 700 "$TEMP_KEY_DIR"
    touch "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"
}

get_connection_host() {
    # Prefer Tailscale hostname, fall back to public IP, then hostname
    if command -v tailscale &>/dev/null; then
        local ts_ip
        ts_ip=$(tailscale ip -4 2>/dev/null || true)
        if [[ -n "$ts_ip" ]]; then
            local ts_name
            ts_name=$(tailscale status --self --json 2>/dev/null | jq -r '.Self.DNSName // empty' 2>/dev/null || true)
            ts_name="${ts_name%.}" # strip trailing dot
            if [[ -n "$ts_name" ]]; then
                echo "$ts_name"
                return
            fi
            echo "$ts_ip"
            return
        fi
    fi

    # Try EC2 metadata for public IP
    local public_ip
    public_ip=$(curl -sf --connect-timeout 1 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)
    if [[ -n "$public_ip" ]]; then
        echo "$public_ip"
        return
    fi

    # Fall back to hostname
    hostname -f 2>/dev/null || hostname
}

cmd_create() {
    local hours="${1:-$DEFAULT_HOURS}"

    # Validate hours is a positive integer
    if ! [[ "$hours" =~ ^[0-9]+$ ]] || [[ "$hours" -lt 1 ]]; then
        die "Hours must be a positive integer (got: $hours)"
    fi

    ensure_dirs

    local id
    id=$(generate_id)
    local now
    now=$(date +%s)
    local expires=$((now + hours * 3600))
    local created
    created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local expires_human
    expires_human=$(date -u -d "@$expires" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$expires" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "in ${hours}h")

    local key_file="$TEMP_KEY_DIR/temp_${id}"

    # Generate temporary key pair
    ssh-keygen -t ed25519 -f "$key_file" -N "" -C "temp-access-${id}" -q
    chmod 600 "$key_file"
    chmod 644 "${key_file}.pub"

    local pubkey
    pubkey=$(cat "${key_file}.pub")

    # Add to authorized_keys with marker comment and restrictions
    # restrict: disables port forwarding, agent forwarding, X11, pty allocation by default
    # Then re-enable pty so the guest can get an interactive shell
    {
        echo "${MARKER_PREFIX} expires=${expires} id=${id} created=${created}"
        echo "restrict,pty ${pubkey}"
    } >> "$AUTHORIZED_KEYS"

    ok "Temporary access created"

    local host
    host=$(get_connection_host)
    local user
    user=$(whoami)

    echo ""
    echo "  Access ID:  ${id}"
    echo "  Expires:    ${expires_human} (${hours}h from now)"
    echo "  User:       ${user}"
    echo "  Host:       ${host}"
    echo ""
    echo "  --- Private key (share this with your guest) ---"
    cat "$key_file"
    echo "  --- End private key ---"
    echo ""
    echo "  Guest connection command:"
    echo "    # Save the private key above to a file, then:"
    echo "    chmod 600 /tmp/temp_key"
    echo "    ssh -i /tmp/temp_key ${user}@${host}"
    echo ""
    echo "  One-liner (guest copies and runs):"
    echo "    bash -c 'cat > /tmp/aoc_${id} << \"KEYEOF\""
    cat "$key_file"
    echo "KEYEOF"
    echo "chmod 600 /tmp/aoc_${id} && ssh -i /tmp/aoc_${id} '${user}@${host}''"
    echo ""
    echo "  To revoke: bash ~/dev-env/scripts/runtime/share.sh revoke ${id}"
    echo "  To revoke all: bash ~/dev-env/scripts/runtime/share.sh revoke all"
}

cmd_list() {
    ensure_dirs

    if [[ ! -f "$AUTHORIZED_KEYS" ]]; then
        echo "  No authorized_keys file found"
        return
    fi

    local now
    now=$(date +%s)
    local found=0

    info "Active temporary access grants"

    while IFS= read -r line; do
        if [[ "$line" == "${MARKER_PREFIX}"* ]]; then
            local expires="" id="" created=""
            # Parse marker fields
            if [[ "$line" =~ expires=([0-9]+) ]]; then expires="${BASH_REMATCH[1]}"; fi
            if [[ "$line" =~ id=([a-f0-9]+) ]]; then id="${BASH_REMATCH[1]}"; fi
            if [[ "$line" =~ created=([^ ]+) ]]; then created="${BASH_REMATCH[1]}"; fi

            local status="ACTIVE"
            local remaining=""
            if [[ -n "$expires" ]]; then
                if [[ "$expires" -le "$now" ]]; then
                    status="EXPIRED"
                else
                    local diff=$((expires - now))
                    local hours=$((diff / 3600))
                    local mins=$(( (diff % 3600) / 60 ))
                    remaining="${hours}h ${mins}m remaining"
                fi
            fi

            found=$((found + 1))
            local expires_human
            expires_human=$(date -u -d "@$expires" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$expires" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")

            echo ""
            echo "  ID:       ${id}"
            echo "  Created:  ${created}"
            echo "  Expires:  ${expires_human}"
            echo "  Status:   ${status}${remaining:+ ($remaining)}"
        fi
    done < "$AUTHORIZED_KEYS"

    if [[ "$found" -eq 0 ]]; then
        echo "  No temporary access grants found"
    else
        echo ""
        echo "  Total: ${found} grant(s)"
    fi
}

cmd_revoke() {
    local target="${1:-}"

    if [[ -z "$target" ]]; then
        die "Usage: $0 revoke [all|<id>]"
    fi

    ensure_dirs

    if [[ ! -f "$AUTHORIZED_KEYS" ]]; then
        echo "  No authorized_keys file — nothing to revoke"
        return
    fi

    local temp_file
    temp_file=$(mktemp)
    local revoked=0
    local skip_next=0

    while IFS= read -r line; do
        if [[ "$line" == "${MARKER_PREFIX}"* ]]; then
            local id=""
            if [[ "$line" =~ id=([a-f0-9]+) ]]; then id="${BASH_REMATCH[1]}"; fi

            if [[ "$target" == "all" ]] || [[ "$id" == "$target" ]]; then
                # Skip this marker and the next line (the key itself)
                skip_next=1
                revoked=$((revoked + 1))

                # Clean up the key file
                rm -f "$TEMP_KEY_DIR/temp_${id}" "$TEMP_KEY_DIR/temp_${id}.pub"
                continue
            fi
        fi

        if [[ "$skip_next" -eq 1 ]]; then
            skip_next=0
            continue
        fi

        echo "$line" >> "$temp_file"
    done < "$AUTHORIZED_KEYS"

    mv "$temp_file" "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"

    if [[ "$revoked" -eq 0 ]]; then
        if [[ "$target" == "all" ]]; then
            echo "  No temporary access grants to revoke"
        else
            die "No grant found with ID: $target"
        fi
    else
        ok "Revoked ${revoked} access grant(s)"
    fi
}

cmd_cleanup() {
    ensure_dirs

    if [[ ! -f "$AUTHORIZED_KEYS" ]]; then
        return
    fi

    local now
    now=$(date +%s)
    local temp_file
    temp_file=$(mktemp)
    local cleaned=0
    local skip_next=0

    while IFS= read -r line; do
        if [[ "$line" == "${MARKER_PREFIX}"* ]]; then
            local expires="" id=""
            if [[ "$line" =~ expires=([0-9]+) ]]; then expires="${BASH_REMATCH[1]}"; fi
            if [[ "$line" =~ id=([a-f0-9]+) ]]; then id="${BASH_REMATCH[1]}"; fi

            if [[ -n "$expires" ]] && [[ "$expires" -le "$now" ]]; then
                skip_next=1
                cleaned=$((cleaned + 1))

                # Clean up the key file
                rm -f "$TEMP_KEY_DIR/temp_${id}" "$TEMP_KEY_DIR/temp_${id}.pub"
                continue
            fi
        fi

        if [[ "$skip_next" -eq 1 ]]; then
            skip_next=0
            continue
        fi

        echo "$line" >> "$temp_file"
    done < "$AUTHORIZED_KEYS"

    mv "$temp_file" "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"

    if [[ "$cleaned" -gt 0 ]]; then
        ok "Cleaned up ${cleaned} expired grant(s)"
    else
        echo "  No expired grants to clean up"
    fi
}

case "${1:-}" in
    create)
        cmd_create "${2:-$DEFAULT_HOURS}"
        ;;
    list)
        cmd_list
        ;;
    revoke)
        [[ $# -lt 2 ]] && die "Usage: $0 revoke [all|<id>]"
        cmd_revoke "$2"
        ;;
    cleanup)
        cmd_cleanup
        ;;
    *)
        echo "Usage: $0 {create|list|revoke|cleanup}" >&2
        echo ""
        echo "  create [hours]   — generate temp SSH key (default: ${DEFAULT_HOURS}h)"
        echo "  list             — show active temporary access grants"
        echo "  revoke [all|id]  — remove specific or all temporary keys"
        echo "  cleanup          — remove expired keys"
        exit 1
        ;;
esac
