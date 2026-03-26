#!/bin/bash
# load-config.sh — Load deployment config from .env file.
#
# Source this from other scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/load-config.sh"
#
# Config resolution order (later wins):
#   1. Defaults (hardcoded below)
#   2. .env file (in repo root)
#   3. Environment variables (set before running the script)
#
# This means env vars always override .env, and .env overrides defaults.
# Scripts that already accept env var overrides continue to work unchanged.

# Find repo root (works whether sourced from scripts/deploy/ or elsewhere)
_LOAD_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$_LOAD_CONFIG_DIR/../.." && pwd)"

# --- Defaults -----------------------------------------------------------------

_defaults() {
    # AWS / EC2
    : "${INSTANCE_TYPE:=t4g.small}"
    : "${AWS_REGION:=$(aws configure get region 2>/dev/null || echo "us-east-1")}"
    : "${VOLUME_SIZE:=20}"
    : "${INSTANCE_NAME:=claude-dev}"
    : "${KEY_NAME:=claude-dev-key}"
    : "${SG_NAME:=claude-dev-sg}"
    : "${SSH_USER:=dev}"
    : "${PROJECT_TAG:=always-on-claude}"

    # Docker
    : "${DOCKER_IMAGE:=ghcr.io/verkyyi/always-on-claude:latest}"
    : "${CONTAINER_NAME:=claude-dev}"
    : "${CONTAINER_HOSTNAME:=claude-dev}"

    # Paths
    : "${DEV_ENV:=$HOME/dev-env}"
    : "${PROJECTS_DIR:=$HOME/projects}"

    # AMI build
    : "${AMI_BUILD_INSTANCE_TYPE:=t3.medium}"
    : "${AMI_BUILD_VOLUME_SIZE:=30}"
}

# --- Load .env ----------------------------------------------------------------

# Save any env vars the caller already set (they take priority over .env)
_save_env_overrides() {
    # Capture current values of all config vars that are already set in the
    # environment. After sourcing .env, we restore these so env vars win.
    _OVERRIDES=()
    for var in INSTANCE_TYPE AWS_REGION VOLUME_SIZE INSTANCE_NAME KEY_NAME \
               SG_NAME SSH_USER PROJECT_TAG DOCKER_IMAGE CONTAINER_NAME \
               CONTAINER_HOSTNAME DEV_ENV PROJECTS_DIR AMI_BUILD_INSTANCE_TYPE \
               AMI_BUILD_VOLUME_SIZE MAX_SESSIONS TAILSCALE_HOSTNAME; do
        if [[ -n "${!var+set}" ]]; then
            _OVERRIDES+=("$var=${!var}")
        fi
    done
}

_restore_env_overrides() {
    for entry in "${_OVERRIDES[@]+"${_OVERRIDES[@]}"}"; do
        local var="${entry%%=*}"
        local val="${entry#*=}"
        export "$var=$val"
    done
}

_save_env_overrides

# Source .env from repo root if it exists
if [[ -f "$_REPO_ROOT/.env" ]]; then
    # shellcheck disable=SC1091
    set -a
    source "$_REPO_ROOT/.env"
    set +a
fi

_restore_env_overrides
_defaults

# Legacy compat: scripts that used TAG instead of PROJECT_TAG
TAG="${PROJECT_TAG}"
# Legacy compat: scripts that used IMAGE instead of DOCKER_IMAGE
IMAGE="${DOCKER_IMAGE}"

# Export for subprocesses
export INSTANCE_TYPE AWS_REGION VOLUME_SIZE INSTANCE_NAME KEY_NAME SG_NAME \
       SSH_USER PROJECT_TAG TAG DOCKER_IMAGE IMAGE CONTAINER_NAME \
       CONTAINER_HOSTNAME DEV_ENV PROJECTS_DIR AMI_BUILD_INSTANCE_TYPE \
       AMI_BUILD_VOLUME_SIZE

# Clean up internals
unset _LOAD_CONFIG_DIR _REPO_ROOT _OVERRIDES
unset -f _defaults _save_env_overrides _restore_env_overrides
