#!/bin/bash
# deploy.sh — Deploy a web app with auto-DNS subdomain and HTTPS
#
# Usage:
#   deploy.sh deploy <project-dir> [app-name]    — deploy or redeploy an app
#   deploy.sh stop <app-name>                    — stop a deployed app
#   deploy.sh restart <app-name>                 — restart a deployed app
#   deploy.sh status                             — show all deployed apps
#   deploy.sh logs <app-name> [lines]            — tail logs for an app
#   deploy.sh remove <app-name>                  — stop and remove an app
#
# Environment variables (set by provisioning):
#   WORKSPACE_ID       — unique workspace identifier
#   WORKSPACE_DOMAIN   — base domain (e.g., alwayson.dev)
#
# Runs on the host. Apps bind to localhost ports; Caddy routes subdomains.

set -euo pipefail

REGISTRY="${HOME}/.deployed-apps.json"
CADDY_APPS_VOLUME="caddy-apps"
COMPOSE_DIR="${HOME}/dev-env"
MIN_PORT=3000
MAX_PORT=9000

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
warn()  { echo "  WARN: $*"; }
die()   { echo "ERROR: $*" >&2; exit 1; }

# --- Ensure registry exists ---
init_registry() {
    if [[ ! -f "$REGISTRY" ]]; then
        echo "[]" > "$REGISTRY"
    fi
}

# --- Read env vars ---
load_env() {
    source "${COMPOSE_DIR}/.env.workspace" 2>/dev/null || true

    WORKSPACE_ID="${WORKSPACE_ID:-}"
    WORKSPACE_DOMAIN="${WORKSPACE_DOMAIN:-}"

    if [[ -z "$WORKSPACE_ID" || -z "$WORKSPACE_DOMAIN" ]]; then
        die "WORKSPACE_ID and WORKSPACE_DOMAIN must be set. Run provisioning first."
    fi
}

# --- Find next available port ---
next_port() {
    local used_ports
    used_ports=$(jq -r '.[].port' "$REGISTRY" 2>/dev/null | sort -n)

    local port=$MIN_PORT
    while [[ $port -le $MAX_PORT ]]; do
        if ! echo "$used_ports" | grep -q "^${port}$" && ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            echo "$port"
            return
        fi
        ((port++))
    done
    die "No available ports in range ${MIN_PORT}-${MAX_PORT}"
}

# --- Detect project type ---
detect_type() {
    local dir="$1"

    if [[ -f "$dir/docker-compose.yml" || -f "$dir/docker-compose.yaml" ]]; then
        echo "docker-compose"
    elif [[ -f "$dir/Dockerfile" ]]; then
        echo "dockerfile"
    elif [[ -f "$dir/package.json" ]]; then
        # Check for common frameworks
        if grep -q '"next"' "$dir/package.json" 2>/dev/null; then
            echo "nextjs"
        elif grep -q '"nuxt"' "$dir/package.json" 2>/dev/null; then
            echo "nuxt"
        else
            echo "node"
        fi
    elif [[ -f "$dir/requirements.txt" || -f "$dir/pyproject.toml" ]]; then
        echo "python"
    elif [[ -f "$dir/index.html" ]]; then
        echo "static"
    else
        echo "unknown"
    fi
}

# --- Start an app based on its type ---
start_app() {
    local name="$1" dir="$2" type="$3" port="$4"
    local container_name="app-${name}"

    info "Starting ${name} (${type}) on port ${port}"

    case "$type" in
        docker-compose)
            cd "$dir"
            # Set PORT env var for the compose project
            PORT="$port" docker compose -p "app-${name}" up -d --build
            ok "Docker Compose app started"
            ;;

        dockerfile)
            docker build -t "app-${name}" "$dir"
            docker rm -f "$container_name" 2>/dev/null || true
            docker run -d \
                --name "$container_name" \
                --restart unless-stopped \
                -e PORT="$port" \
                -p "127.0.0.1:${port}:${port}" \
                "app-${name}"
            ok "Docker container started"
            ;;

        nextjs)
            docker rm -f "$container_name" 2>/dev/null || true
            docker run -d \
                --name "$container_name" \
                --restart unless-stopped \
                -v "${dir}:/app" \
                -w /app \
                -e PORT="$port" \
                -p "127.0.0.1:${port}:${port}" \
                node:22-slim \
                sh -c "npm install && npm run build && npm start"
            ok "Next.js app started"
            ;;

        nuxt|node)
            docker rm -f "$container_name" 2>/dev/null || true
            docker run -d \
                --name "$container_name" \
                --restart unless-stopped \
                -v "${dir}:/app" \
                -w /app \
                -e PORT="$port" \
                -p "127.0.0.1:${port}:${port}" \
                node:22-slim \
                sh -c "npm install && npm start"
            ok "Node.js app started"
            ;;

        python)
            docker rm -f "$container_name" 2>/dev/null || true
            # Detect if it's a FastAPI/uvicorn or Flask/gunicorn project
            local cmd="pip install -r requirements.txt 2>/dev/null; "
            if [[ -f "$dir/pyproject.toml" ]]; then
                cmd="pip install -e . 2>/dev/null; "
            fi
            if grep -q "fastapi\|uvicorn" "$dir/requirements.txt" 2>/dev/null || \
               grep -q "fastapi\|uvicorn" "$dir/pyproject.toml" 2>/dev/null; then
                cmd+="uvicorn main:app --host 0.0.0.0 --port ${port}"
            else
                cmd+="gunicorn -b 0.0.0.0:${port} app:app"
            fi
            docker run -d \
                --name "$container_name" \
                --restart unless-stopped \
                -v "${dir}:/app" \
                -w /app \
                -e PORT="$port" \
                -p "127.0.0.1:${port}:${port}" \
                python:3.12-slim \
                sh -c "$cmd"
            ok "Python app started"
            ;;

        static)
            docker rm -f "$container_name" 2>/dev/null || true
            docker run -d \
                --name "$container_name" \
                --restart unless-stopped \
                -v "${dir}:/usr/share/caddy:ro" \
                -p "127.0.0.1:${port}:80" \
                caddy:2 \
                caddy file-server --root /usr/share/caddy --listen ":80"
            ok "Static site started"
            ;;

        *)
            die "Unknown project type: ${type}. Add a Dockerfile, package.json, requirements.txt, or index.html."
            ;;
    esac
}

# --- Write Caddy route config for an app ---
configure_caddy() {
    local name="$1" port="$2"
    local domain="${name}.${WORKSPACE_ID}.${WORKSPACE_DOMAIN}"
    local caddy_config

    # Write per-app Caddy config snippet
    # These are imported by the main Caddyfile via `import /etc/caddy/apps/*`
    caddy_config="@${name} host ${domain}
handle @${name} {
	reverse_proxy 127.0.0.1:${port}
}
"

    # Write to the caddy-apps volume via docker cp
    local tmpfile
    tmpfile=$(mktemp)
    echo "$caddy_config" > "$tmpfile"

    docker cp "$tmpfile" "caddy:/etc/caddy/apps/${name}.caddy" 2>/dev/null || {
        # If Caddy container isn't running, start the deploy profile
        info "Starting Caddy reverse proxy"
        cd "$COMPOSE_DIR"
        if [[ "${WORKSPACE_TYPE:-ec2}" == "local-mac" ]]; then
            docker compose -f docker-compose.yml -f docker-compose.mac.yml --profile deploy up -d caddy
        else
            sudo --preserve-env=HOME docker compose --profile deploy up -d caddy
        fi
        sleep 2
        docker cp "$tmpfile" "caddy:/etc/caddy/apps/${name}.caddy"
    }
    rm -f "$tmpfile"

    # Reload Caddy config
    docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || \
        warn "Caddy reload failed — config may need manual review"

    ok "Caddy configured for https://${domain}"
}

# --- Register app in the JSON registry ---
register_app() {
    local name="$1" dir="$2" type="$3" port="$4"
    local domain="${name}.${WORKSPACE_ID}.${WORKSPACE_DOMAIN}"
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Remove existing entry if redeploying
    local updated
    updated=$(jq --arg name "$name" '[.[] | select(.name != $name)]' "$REGISTRY")

    # Add new entry
    updated=$(echo "$updated" | jq \
        --arg name "$name" \
        --arg domain "$domain" \
        --arg port "$port" \
        --arg path "$dir" \
        --arg type "$type" \
        --arg deployed_at "$now" \
        '. + [{name: $name, domain: $domain, port: ($port | tonumber), path: $path, type: $type, deployed_at: $deployed_at}]')

    echo "$updated" | jq . > "$REGISTRY"
}

# --- Check app health ---
check_health() {
    local port="$1"
    local attempts=0
    local max_attempts=15

    while [[ $attempts -lt $max_attempts ]]; do
        if curl -sf -o /dev/null "http://127.0.0.1:${port}" 2>/dev/null; then
            return 0
        fi
        ((attempts++))
        sleep 2
    done
    return 1
}

# --- Commands ---

cmd_deploy() {
    local dir="${1:-.}"
    local name="${2:-}"

    # Resolve absolute path
    dir=$(cd "$dir" && pwd)

    # Default app name from directory
    if [[ -z "$name" ]]; then
        name=$(basename "$dir" | tr '[:upper:]' '[:lower:]' | tr ' ._' '---' | sed 's/[^a-z0-9-]//g')
    fi

    [[ -z "$name" ]] && die "Could not determine app name"

    load_env
    init_registry

    local type
    type=$(detect_type "$dir")
    info "Detected project type: ${type}"

    # Check if app is already deployed (reuse port)
    local existing_port
    existing_port=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .port' "$REGISTRY" 2>/dev/null)

    local port
    if [[ -n "$existing_port" && "$existing_port" != "null" ]]; then
        port="$existing_port"
        info "Redeploying ${name} on existing port ${port}"
    else
        port=$(next_port)
        info "Assigning port ${port}"
    fi

    start_app "$name" "$dir" "$type" "$port"
    configure_caddy "$name" "$port"
    register_app "$name" "$dir" "$type" "$port"

    local domain="${name}.${WORKSPACE_ID}.${WORKSPACE_DOMAIN}"
    info "Verifying health"
    if check_health "$port"; then
        ok "App is responding"
    else
        warn "App not responding yet on port ${port} — it may still be starting"
    fi

    echo ""
    echo "  Deployed: https://${domain}"
    echo "  Port:     ${port}"
    echo "  Type:     ${type}"
    echo ""
}

cmd_stop() {
    local name="$1"
    [[ -z "$name" ]] && die "Usage: deploy.sh stop <app-name>"

    init_registry

    local type
    type=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .type' "$REGISTRY" 2>/dev/null)

    if [[ -z "$type" || "$type" == "null" ]]; then
        die "App '${name}' not found in registry"
    fi

    info "Stopping ${name}"

    case "$type" in
        docker-compose)
            local app_dir
            app_dir=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .path' "$REGISTRY")
            cd "$app_dir" && docker compose -p "app-${name}" stop
            ;;
        *)
            docker stop "app-${name}" 2>/dev/null || true
            ;;
    esac

    ok "Stopped ${name}"
}

cmd_restart() {
    local name="$1"
    [[ -z "$name" ]] && die "Usage: deploy.sh restart <app-name>"

    init_registry

    local type
    type=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .type' "$REGISTRY" 2>/dev/null)

    if [[ -z "$type" || "$type" == "null" ]]; then
        die "App '${name}' not found in registry"
    fi

    info "Restarting ${name}"

    case "$type" in
        docker-compose)
            local app_dir
            app_dir=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .path' "$REGISTRY")
            local port
            port=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .port' "$REGISTRY")
            cd "$app_dir" && PORT="$port" docker compose -p "app-${name}" restart
            ;;
        *)
            docker restart "app-${name}" 2>/dev/null || die "Failed to restart ${name}"
            ;;
    esac

    ok "Restarted ${name}"
}

cmd_status() {
    init_registry

    local apps
    apps=$(jq -r '.[] | .name' "$REGISTRY" 2>/dev/null)

    if [[ -z "$apps" ]]; then
        echo ""
        echo "  No deployed apps."
        echo "  Use 'deploy.sh deploy <dir> [name]' to deploy your first app."
        echo ""
        return
    fi

    echo ""
    printf "  %-20s %-8s %-18s %-10s %s\n" "NAME" "PORT" "TYPE" "STATUS" "DOMAIN"
    printf "  %-20s %-8s %-18s %-10s %s\n" "----" "----" "----" "------" "------"

    while IFS= read -r entry; do
        local name port type domain deployed_at
        name=$(echo "$entry" | jq -r '.name')
        port=$(echo "$entry" | jq -r '.port')
        type=$(echo "$entry" | jq -r '.type')
        domain=$(echo "$entry" | jq -r '.domain')

        # Check container/process status
        local status="unknown"
        if [[ "$type" == "docker-compose" ]]; then
            local app_dir
            app_dir=$(echo "$entry" | jq -r '.path')
            if cd "$app_dir" 2>/dev/null && docker compose -p "app-${name}" ps --status running 2>/dev/null | grep -q .; then
                status="running"
            else
                status="stopped"
            fi
        else
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^app-${name}$"; then
                status="running"
            else
                status="stopped"
            fi
        fi

        printf "  %-20s %-8s %-18s %-10s %s\n" "$name" "$port" "$type" "$status" "$domain"
    done < <(jq -c '.[]' "$REGISTRY" 2>/dev/null)

    echo ""
}

cmd_logs() {
    local name="$1"
    local lines="${2:-100}"
    [[ -z "$name" ]] && die "Usage: deploy.sh logs <app-name> [lines]"

    init_registry

    local type
    type=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .type' "$REGISTRY" 2>/dev/null)

    if [[ -z "$type" || "$type" == "null" ]]; then
        die "App '${name}' not found in registry"
    fi

    case "$type" in
        docker-compose)
            local app_dir
            app_dir=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .path' "$REGISTRY")
            cd "$app_dir" && docker compose -p "app-${name}" logs --tail "$lines"
            ;;
        *)
            docker logs --tail "$lines" "app-${name}" 2>&1
            ;;
    esac
}

cmd_remove() {
    local name="$1"
    [[ -z "$name" ]] && die "Usage: deploy.sh remove <app-name>"

    init_registry

    local type
    type=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .type' "$REGISTRY" 2>/dev/null)

    if [[ -z "$type" || "$type" == "null" ]]; then
        die "App '${name}' not found in registry"
    fi

    info "Removing ${name}"

    # Stop and remove container(s)
    case "$type" in
        docker-compose)
            local app_dir
            app_dir=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .path' "$REGISTRY")
            cd "$app_dir" && docker compose -p "app-${name}" down 2>/dev/null || true
            ;;
        *)
            docker rm -f "app-${name}" 2>/dev/null || true
            ;;
    esac

    # Remove Caddy config
    docker exec caddy rm -f "/etc/caddy/apps/${name}.caddy" 2>/dev/null || true
    docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true

    # Remove from registry
    local updated
    updated=$(jq --arg name "$name" '[.[] | select(.name != $name)]' "$REGISTRY")
    echo "$updated" | jq . > "$REGISTRY"

    ok "Removed ${name}"
}

# --- Main ---
case "${1:-}" in
    deploy)
        cmd_deploy "${2:-}" "${3:-}"
        ;;
    stop)
        cmd_stop "${2:-}"
        ;;
    restart)
        cmd_restart "${2:-}"
        ;;
    status)
        cmd_status
        ;;
    logs)
        cmd_logs "${2:-}" "${3:-}"
        ;;
    remove)
        cmd_remove "${2:-}"
        ;;
    *)
        echo "Usage: deploy.sh {deploy|stop|restart|status|logs|remove}" >&2
        echo "" >&2
        echo "  deploy <dir> [name]   Deploy or redeploy an app" >&2
        echo "  stop <name>           Stop a deployed app" >&2
        echo "  restart <name>        Restart a deployed app" >&2
        echo "  status                Show all deployed apps" >&2
        echo "  logs <name> [lines]   Tail logs for an app" >&2
        echo "  remove <name>         Stop and remove an app" >&2
        exit 1
        ;;
esac
