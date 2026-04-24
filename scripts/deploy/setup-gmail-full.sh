#!/bin/bash
# setup-gmail-full.sh — Optional helper to configure gmail-full for Codex and Claude.
#
# Usage:
#   GMAIL_FULL_SOURCE_DIR="$HOME/.gmail-mcp" bash scripts/deploy/setup-gmail-full.sh
#
# Or provide individual files:
#   GMAIL_FULL_CREDENTIALS_FILE=/path/to/credentials.json \
#   GMAIL_FULL_OAUTH_FILE=/path/to/gcp-oauth.keys.json \
#   bash scripts/deploy/setup-gmail-full.sh
#
# On provisioned hosts, the default target is ~/.codex/gmail-mcp so the same
# files are visible to both the host and the container. Elsewhere, the default
# target is ~/.gmail-mcp.

set -euo pipefail

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
skip()  { echo "  SKIP: $* (already done)"; }
die()   { echo "ERROR: $*" >&2; exit 1; }

DEV_ENV_ROOT="${DEV_ENV:-$HOME/dev-env}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CLAUDE_SCOPE="${CLAUDE_SCOPE:-user}"
GMAIL_FULL_PACKAGE="${GMAIL_FULL_PACKAGE:-@gongrzhe/server-gmail-autoauth-mcp}"
GMAIL_FULL_SOURCE_DIR="${GMAIL_FULL_SOURCE_DIR:-}"
GMAIL_FULL_CREDENTIALS_FILE="${GMAIL_FULL_CREDENTIALS_FILE:-}"
GMAIL_FULL_OAUTH_FILE="${GMAIL_FULL_OAUTH_FILE:-}"
CHANGED=0

default_target_dir() {
    if [[ -f "$DEV_ENV_ROOT/.provisioned" ]]; then
        echo "$CODEX_HOME/gmail-mcp"
    else
        echo "$HOME/.gmail-mcp"
    fi
}

trim_trailing_blank_lines() {
    local file="$1"

    awk '
        {
            lines[NR] = $0
        }
        $0 ~ /[^[:space:]]/ {
            last = NR
        }
        END {
            for (i = 1; i <= last; i++) {
                print lines[i]
            }
        }
    ' "$file"
}

copy_if_changed() {
    local src="$1"
    local dest="$2"
    local mode="$3"

    mkdir -p "$(dirname "$dest")"

    if [[ ! -f "$dest" ]] || ! cmp -s "$src" "$dest"; then
        cp "$src" "$dest"
        CHANGED=1
    fi

    chmod "$mode" "$dest"
}

resolve_source_files() {
    if [[ -n "$GMAIL_FULL_SOURCE_DIR" ]]; then
        if [[ -z "$GMAIL_FULL_CREDENTIALS_FILE" ]]; then
            GMAIL_FULL_CREDENTIALS_FILE="$GMAIL_FULL_SOURCE_DIR/credentials.json"
        fi
        if [[ -z "$GMAIL_FULL_OAUTH_FILE" ]]; then
            GMAIL_FULL_OAUTH_FILE="$GMAIL_FULL_SOURCE_DIR/gcp-oauth.keys.json"
        fi
    fi
}

ensure_credentials() {
    local target_dir="$1"
    local target_credentials="$2"
    local target_oauth="$3"

    resolve_source_files

    mkdir -p "$target_dir"
    chmod 700 "$target_dir"

    if [[ -n "$GMAIL_FULL_CREDENTIALS_FILE" || -n "$GMAIL_FULL_OAUTH_FILE" ]]; then
        [[ -n "$GMAIL_FULL_CREDENTIALS_FILE" ]] || die "Set both GMAIL_FULL_CREDENTIALS_FILE and GMAIL_FULL_OAUTH_FILE."
        [[ -n "$GMAIL_FULL_OAUTH_FILE" ]] || die "Set both GMAIL_FULL_CREDENTIALS_FILE and GMAIL_FULL_OAUTH_FILE."
        [[ -f "$GMAIL_FULL_CREDENTIALS_FILE" ]] || die "Credentials file not found: $GMAIL_FULL_CREDENTIALS_FILE"
        [[ -f "$GMAIL_FULL_OAUTH_FILE" ]] || die "OAuth keys file not found: $GMAIL_FULL_OAUTH_FILE"

        copy_if_changed "$GMAIL_FULL_CREDENTIALS_FILE" "$target_credentials" 600
        copy_if_changed "$GMAIL_FULL_OAUTH_FILE" "$target_oauth" 600
        ok "Credential files available at $target_dir"
        return 0
    fi

    if [[ -f "$target_credentials" && -f "$target_oauth" ]]; then
        skip "Credential files"
        chmod 600 "$target_credentials" "$target_oauth"
        return 0
    fi

    die "Provide GMAIL_FULL_SOURCE_DIR or both GMAIL_FULL_CREDENTIALS_FILE and GMAIL_FULL_OAUTH_FILE."
}

sync_codex_config() {
    local target_credentials="$1"
    local target_oauth="$2"
    local config_dir="$CODEX_HOME"
    local config_file="$config_dir/config.toml"
    local stripped merged

    mkdir -p "$config_dir"
    stripped=$(mktemp)
    merged=$(mktemp)

    if [[ -f "$config_file" ]]; then
        awk '
            BEGIN { skip = 0 }
            /^\[/ {
                if ($0 ~ /^\[mcp_servers\.gmail-full(\.env|\.tools\.search_emails)?\]$/) {
                    skip = 1
                    next
                }
                if (skip) {
                    skip = 0
                }
            }
            !skip { print }
        ' "$config_file" > "$stripped"
        trim_trailing_blank_lines "$stripped" > "$merged"
    else
        : > "$merged"
    fi

    if [[ -s "$merged" ]]; then
        printf '\n\n' >> "$merged"
    fi

    cat >> "$merged" <<EOF
[mcp_servers.gmail-full]
command = "npx"
args = ["$GMAIL_FULL_PACKAGE"]

[mcp_servers.gmail-full.env]
GMAIL_CREDENTIALS_PATH = "$target_credentials"
GMAIL_OAUTH_PATH = "$target_oauth"

[mcp_servers.gmail-full.tools.search_emails]
approval_mode = "approve"
EOF

    if [[ -f "$config_file" ]] && cmp -s "$merged" "$config_file"; then
        skip "Codex gmail-full MCP"
        rm -f "$merged" "$stripped"
        return 0
    fi

    mv "$merged" "$config_file"
    chmod 600 "$config_file"
    rm -f "$stripped"
    CHANGED=1
    ok "Configured Codex gmail-full MCP"
}

claude_mcp_matches() {
    local target_credentials="$1"
    local target_oauth="$2"
    local output

    if ! command -v claude >/dev/null 2>&1; then
        return 1
    fi

    if ! output=$(claude mcp get gmail-full 2>/dev/null); then
        return 1
    fi

    [[ "$output" == *"Scope:"* ]] || return 1
    [[ "$output" == *"Command: npx"* ]] || return 1
    [[ "$output" == *"Args: $GMAIL_FULL_PACKAGE"* ]] || return 1
    [[ "$output" == *"GMAIL_CREDENTIALS_PATH=$target_credentials"* ]] || return 1
    [[ "$output" == *"GMAIL_OAUTH_PATH=$target_oauth"* ]] || return 1
}

sync_claude_config() {
    local target_credentials="$1"
    local target_oauth="$2"
    local json

    if ! command -v claude >/dev/null 2>&1; then
        skip "Claude Code gmail-full MCP (claude not installed)"
        return 0
    fi

    if claude_mcp_matches "$target_credentials" "$target_oauth"; then
        skip "Claude Code gmail-full MCP"
        return 0
    fi

    if claude mcp get gmail-full >/dev/null 2>&1; then
        claude mcp remove "gmail-full" -s "$CLAUDE_SCOPE" >/dev/null 2>&1 || true
    fi

    json=$(printf '{"type":"stdio","command":"npx","args":["%s"],"env":{"GMAIL_CREDENTIALS_PATH":"%s","GMAIL_OAUTH_PATH":"%s"}}' \
        "$GMAIL_FULL_PACKAGE" "$target_credentials" "$target_oauth")

    claude mcp add-json -s "$CLAUDE_SCOPE" gmail-full "$json" >/dev/null
    CHANGED=1
    ok "Configured Claude Code gmail-full MCP"
}

main() {
    local target_dir target_credentials target_oauth
    target_dir="${GMAIL_FULL_TARGET_DIR:-$(default_target_dir)}"
    target_credentials="$target_dir/credentials.json"
    target_oauth="$target_dir/gcp-oauth.keys.json"

    info "gmail-full setup"
    echo "  Target dir: $target_dir"

    ensure_credentials "$target_dir" "$target_credentials" "$target_oauth"
    sync_codex_config "$target_credentials" "$target_oauth"
    sync_claude_config "$target_credentials" "$target_oauth"

    echo ""
    if [[ "$CHANGED" -eq 1 ]]; then
        echo "STATUS: updated"
    else
        echo "STATUS: unchanged"
    fi
}

main "$@"
