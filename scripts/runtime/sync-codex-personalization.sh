#!/bin/bash
# sync-codex-personalization.sh — Materialize repo-managed Codex home state.
#
# This keeps the provisioned host's durable Codex setup in sync with files that
# live in this repo instead of relying on local plugin activation behavior.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_HOME="$SCRIPT_DIR/codex-home"
SOURCE_PROJECTS="$SCRIPT_DIR/codex-projects"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
PROJECTS_DIR="${PROJECTS_DIR:-$HOME/projects}"
CONFIG_FILE="$CODEX_HOME/config.toml"

CHANGED=0

sync_file() {
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

sync_dir() {
    local src="$1"
    local dest="$2"

    mkdir -p "$(dirname "$dest")"

    if [[ ! -d "$dest" ]] || ! diff -qr "$src" "$dest" >/dev/null 2>&1; then
        rm -rf "$dest"
        cp -a "$src" "$dest"
        CHANGED=1
    fi
}

sync_project_file_if_present() {
    local repo="$1"
    local relative_path="$2"
    local src="$3"
    local mode="$4"
    local repo_root="$PROJECTS_DIR/$repo"

    if [[ ! -d "$repo_root" ]]; then
        return 0
    fi

    sync_file "$src" "$repo_root/$relative_path" "$mode"
}

sync_managed_mcp_config() {
    local stripped merged
    stripped=$(mktemp)
    merged=$(mktemp)

    if [[ -f "$CONFIG_FILE" ]]; then
        awk '
            BEGIN { skip = 0 }
            /^\[mcp_servers\.(context7|fetch|playwright|openaiDeveloperDocs)\]$/ {
                skip = 1
                next
            }
            /^\[/ { skip = 0 }
            !skip { print }
        ' "$CONFIG_FILE" > "$stripped"

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
        ' "$stripped" > "$merged"
    else
        : > "$merged"
    fi

    if [[ -s "$merged" ]]; then
        printf '\n\n' >> "$merged"
    fi
    awk -v codex_home="$CODEX_HOME" '
        {
            gsub("/home/dev/.codex", codex_home)
            print
        }
    ' "$SOURCE_HOME/mcp-config.toml" >> "$merged"

    if [[ ! -f "$CONFIG_FILE" ]] || ! cmp -s "$merged" "$CONFIG_FILE"; then
        mv "$merged" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        CHANGED=1
    else
        rm -f "$merged"
    fi

    rm -f "$stripped"
}

if [[ -x "$SCRIPT_DIR/sync-codex-config.sh" ]]; then
    codex_config_status=$(CODEX_HOME="$CODEX_HOME" "$SCRIPT_DIR/sync-codex-config.sh")
    if [[ "$codex_config_status" == "updated" ]]; then
        CHANGED=1
    fi
fi

mkdir -p "$CODEX_HOME" "$CODEX_HOME/bin" "$CODEX_HOME/skills"

sync_file "$SOURCE_HOME/AGENTS.md" "$CODEX_HOME/AGENTS.md" 644
sync_file "$SOURCE_HOME/bin/fetch-mcp.sh" "$CODEX_HOME/bin/fetch-mcp.sh" 755
sync_file "$SOURCE_HOME/bin/playwright-mcp.sh" "$CODEX_HOME/bin/playwright-mcp.sh" 755

sync_dir "$SOURCE_HOME/skills/futuapi" "$CODEX_HOME/skills/futuapi"
sync_dir "$SOURCE_HOME/skills/install-futu-opend" "$CODEX_HOME/skills/install-futu-opend"
sync_dir "$SOURCE_HOME/skills/deploy-proxy" "$CODEX_HOME/skills/deploy-proxy"
sync_dir "$SOURCE_HOME/skills/release-plugin" "$CODEX_HOME/skills/release-plugin"
sync_dir "$SOURCE_HOME/skills/schedule-host-job" "$CODEX_HOME/skills/schedule-host-job"

sync_managed_mcp_config

sync_project_file_if_present "ainbox" ".codex/config.toml" "$SOURCE_PROJECTS/ainbox/.codex/config.toml" 644
sync_project_file_if_present "ainbox" ".codex/hooks.json" "$SOURCE_PROJECTS/ainbox/.codex/hooks.json" 644
sync_project_file_if_present "agentfolio" ".codex/config.toml" "$SOURCE_PROJECTS/agentfolio/.codex/config.toml" 644

if [[ "$CHANGED" -eq 1 ]]; then
    echo "updated"
else
    echo "unchanged"
fi
