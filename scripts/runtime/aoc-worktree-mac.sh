#!/bin/bash
# aoc-worktree-mac.sh — Manage Mac mini worktrees through the container.

set -euo pipefail

DOCKER="${DOCKER:-/opt/homebrew/bin/docker}"
REPO="${AOC_REPO:-$HOME/always-on-claude}"
CONTAINER="${AOC_CONTAINER:-claude-dev}"
PROJECTS_HOST="${AOC_PROJECTS_HOST:-$HOME/projects}"
PROJECTS_CONTAINER="${AOC_PROJECTS_CONTAINER:-/home/dev/projects}"
HELPER_CONTAINER="${AOC_WORKTREE_HELPER_CONTAINER:-/home/dev/dev-env/scripts/runtime/worktree-helper.sh}"
MENU_CACHE_DIR="${AOC_MENU_CACHE_DIR:-$HOME/.cache/aoc/start-menu}"

ensure_container() {
  if ! "$DOCKER" ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "$CONTAINER is not running. Start it first with aoc."
    exit 1
  fi
}

to_container_path() {
  local path="$1"
  if [[ "$path" == "$PROJECTS_HOST"* ]]; then
    echo "${PROJECTS_CONTAINER}${path#"$PROJECTS_HOST"}"
  else
    echo "$path"
  fi
}

to_host_output() {
  sed "s#${PROJECTS_CONTAINER//\\/\\\\}#${PROJECTS_HOST//\\/\\\\}#g"
}

run_helper() {
  ensure_container
  "$DOCKER" exec -i "$CONTAINER" bash "$HELPER_CONTAINER" "$@" | to_host_output
}

repo_cache_key() {
  echo "$1" | tr '/:' '__'
}

cache_warning_file() {
  echo "$MENU_CACHE_DIR/warnings/$(repo_cache_key "$1")"
}

cache_refreshing_file() {
  echo "$MENU_CACHE_DIR/refreshing/$(repo_cache_key "$1")"
}

cache_cleanup_stamp() {
  echo "$MENU_CACHE_DIR/cleanup.stamp"
}

project_repos_host() {
  find "$PROJECTS_HOST" -maxdepth 3 -name .git -type d 2>/dev/null | sort
}

show_overview() {
  ensure_container

  echo "Sessions"
  tmux list-sessions -F '#{session_name}\t#{session_attached}\t#{@aoc_path}\t#{@aoc_repo}\t#{@aoc_branch}' 2>/dev/null \
    | awk -F '\t' 'BEGIN{count=0} $1 ~ /^(claude|codex)-/ {count++; state=($2>0?"attached":"idle"); printf "  %s  %s  %s  %s\n",$1,state,$4,$5} END{if(count==0) print "  (none)"}'

  echo ""
  echo "Blocked repos"
  local repo_dir repo_path warning_file message blocked=0
  while IFS= read -r repo_dir; do
    repo_path=$(dirname "$repo_dir")
    warning_file=$(cache_warning_file "$repo_path")
    if [[ -f "$warning_file" ]]; then
      message=$(cat "$warning_file" 2>/dev/null || true)
      printf '  %s  %s\n' "$repo_path" "${message:-blocked}"
      blocked=1
    fi
  done < <(project_repos_host)
  [[ $blocked -eq 0 ]] && echo "  (none)"

  echo ""
  echo "Refreshing repos"
  local refreshing=0 refreshing_file
  while IFS= read -r repo_dir; do
    repo_path=$(dirname "$repo_dir")
    refreshing_file=$(cache_refreshing_file "$repo_path")
    if [[ -f "$refreshing_file" ]]; then
      printf '  %s\n' "$repo_path"
      refreshing=1
    fi
  done < <(project_repos_host)
  [[ $refreshing -eq 0 ]] && echo "  (none)"

  echo ""
  echo "Cleanup"
  if [[ -f "$(cache_cleanup_stamp)" ]]; then
    printf '  last run: %s\n' "$(date -r "$(cache_cleanup_stamp)" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$(cache_cleanup_stamp)")"
  else
    echo "  last run: never"
  fi

  echo ""
  run_helper cleanup --dry-run
}

cmd_status() {
  local path="$1"
  ensure_container
  "$DOCKER" exec -i "$CONTAINER" bash -lc \
    "git -C \"$(to_container_path "$path")\" status --short --branch" | to_host_output
}

case "${1:-}" in
  create)
    [[ $# -lt 3 ]] && { echo "Usage: $0 create <repo-path> <branch>" >&2; exit 1; }
    run_helper create "$(to_container_path "$2")" "$3"
    ;;
  remove)
    [[ $# -lt 2 ]] && { echo "Usage: $0 remove <worktree-path>" >&2; exit 1; }
    run_helper remove "$(to_container_path "$2")"
    ;;
  list-repos)
    run_helper list-repos
    ;;
  list-worktrees)
    [[ $# -lt 2 ]] && { echo "Usage: $0 list-worktrees <repo-path>" >&2; exit 1; }
    run_helper list-worktrees "$(to_container_path "$2")"
    ;;
  default-branch)
    [[ $# -lt 2 ]] && { echo "Usage: $0 default-branch <repo-path>" >&2; exit 1; }
    run_helper default-branch "$(to_container_path "$2")"
    ;;
  sync-repo)
    [[ $# -lt 2 ]] && { echo "Usage: $0 sync-repo <repo-path>" >&2; exit 1; }
    run_helper sync-repo "$(to_container_path "$2")"
    ;;
  create-session-worktree)
    [[ $# -lt 2 ]] && { echo "Usage: $0 create-session-worktree <repo-path>" >&2; exit 1; }
    run_helper create-session-worktree "$(to_container_path "$2")"
    ;;
  recover-dirty-repo)
    [[ $# -lt 2 ]] && { echo "Usage: $0 recover-dirty-repo <repo-path>" >&2; exit 1; }
    run_helper recover-dirty-repo "$(to_container_path "$2")"
    ;;
  cleanup)
    shift
    args=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --keep-path|--repo)
          args+=("$1" "$(to_container_path "$2")")
          shift 2
          ;;
        *)
          args+=("$1")
          shift
          ;;
      esac
    done
    run_helper cleanup "${args[@]}"
    ;;
  status)
    [[ $# -lt 2 ]] && { echo "Usage: $0 status <worktree-path>" >&2; exit 1; }
    cmd_status "$2"
    ;;
  overview)
    show_overview
    ;;
  *)
    echo "Usage: $0 {create|remove|list-repos|list-worktrees|default-branch|sync-repo|create-session-worktree|recover-dirty-repo|cleanup|status|overview}" >&2
    exit 1
    ;;
esac
