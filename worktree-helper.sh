#!/bin/bash
# worktree-helper.sh — Manage git worktrees inside the dev container
#
# Subcommands:
#   create <repo-path> <branch>   — create a worktree for the given branch
#   remove <worktree-path>        — remove a worktree and prune
#   list-repos                    — discover all repos and worktrees under /home/dev
#
# Runs inside the container; bind-mounted via ~/dev-env:/home/dev/dev-env:ro

set -euo pipefail

sanitize_branch() {
    echo "$1" | tr '/' '-'
}

cmd_create() {
    local repo_path="$1" branch="$2"
    local sanitized
    sanitized=$(sanitize_branch "$branch")
    local worktree_path="${repo_path}--${sanitized}"

    if [[ -d "$worktree_path" ]]; then
        echo "Error: directory already exists: $worktree_path" >&2
        exit 1
    fi

    # Check if the branch exists in the repo
    if git -C "$repo_path" rev-parse --verify "$branch" &>/dev/null; then
        git -C "$repo_path" worktree add "$worktree_path" "$branch"
    else
        git -C "$repo_path" worktree add -b "$branch" "$worktree_path"
    fi

    echo "$worktree_path"
}

cmd_remove() {
    local worktree_path="$1"

    if [[ ! -e "$worktree_path/.git" ]]; then
        echo "Error: not a worktree: $worktree_path" >&2
        exit 1
    fi

    # Read the main repo path from the .git file
    local git_file="$worktree_path/.git"
    local gitdir
    gitdir=$(sed 's/^gitdir: //' "$git_file")
    # gitdir points to <main-repo>/.git/worktrees/<name>
    local main_git="${gitdir%/worktrees/*}"
    local main_repo="${main_git%/.git}"

    git -C "$main_repo" worktree remove "$worktree_path"
    git -C "$main_repo" worktree prune
}

cmd_list_repos() {
    # Find all .git entries (directories = repos, files = worktrees)
    while IFS= read -r git_entry; do
        local dir
        dir=$(dirname "$git_entry")
        local branch

        if [[ -d "$git_entry" ]]; then
            # Regular repo — .git is a directory
            branch=$(git -C "$dir" branch --show-current 2>/dev/null || echo "unknown")
            echo "REPO|${dir}|${branch}"
        elif [[ -f "$git_entry" ]]; then
            # Worktree — .git is a file
            branch=$(git -C "$dir" branch --show-current 2>/dev/null || echo "unknown")
            echo "WORKTREE|${dir}|${branch}"
        fi
    done < <(find /home/dev -maxdepth 3 -name ".git" \( -type d -o -type f \) 2>/dev/null | sort)
}

case "${1:-}" in
    create)
        [[ $# -lt 3 ]] && { echo "Usage: $0 create <repo-path> <branch>" >&2; exit 1; }
        cmd_create "$2" "$3"
        ;;
    remove)
        [[ $# -lt 2 ]] && { echo "Usage: $0 remove <worktree-path>" >&2; exit 1; }
        cmd_remove "$2"
        ;;
    list-repos)
        cmd_list_repos
        ;;
    *)
        echo "Usage: $0 {create|remove|list-repos}" >&2
        exit 1
        ;;
esac
