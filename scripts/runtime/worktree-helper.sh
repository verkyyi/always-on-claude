#!/bin/bash
# worktree-helper.sh — Manage git worktrees inside the dev container
#
# Subcommands:
#   create <repo-path> <branch>   — create a worktree for the given branch
#   remove <worktree-path>        — remove a worktree and prune
#   list-repos                    — discover all repos and worktrees under /home/dev
#   list-worktrees <repo-path>    — list worktrees for a specific repo
#   cleanup [--dry-run|--force]   — clean up merged/stale worktrees
#
# Runs on the host; ~/projects is bind-mounted into the container

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
    done < <(find "$HOME/projects" -maxdepth 3 -name ".git" \( -type d -o -type f \) 2>/dev/null | sort)
}

cmd_list_worktrees() {
    local repo_path="$1"

    if [[ ! -d "$repo_path/.git" ]]; then
        echo "Error: not a git repo: $repo_path" >&2
        exit 1
    fi

    # git worktree list shows main + worktrees; skip the main repo itself
    local wt_path="" wt_branch=""
    while IFS= read -r line; do
        if [[ "$line" == "worktree "* ]]; then
            wt_path="${line#worktree }"
        elif [[ "$line" == "branch "* ]]; then
            wt_branch="${line#branch refs/heads/}"
            # Skip the main repo itself
            if [[ "$wt_path" != "$repo_path" ]]; then
                echo "${wt_path}|${wt_branch}"
            fi
        fi
    done < <(git -C "$repo_path" worktree list --porcelain 2>/dev/null)
}

STALE_DAYS=7

# Detect the default branch (main or master) for a given repo
detect_default_branch() {
    local repo_path="$1"
    for candidate in main master; do
        if git -C "$repo_path" rev-parse --verify "$candidate" &>/dev/null; then
            echo "$candidate"
            return
        fi
    done
    echo "main"
}

# Get the number of days since the last commit on a branch
days_since_last_commit() {
    local repo_path="$1" branch="$2"
    local last_epoch
    last_epoch=$(git -C "$repo_path" log -1 --format='%ct' "$branch" 2>/dev/null || echo "0")
    local now_epoch
    now_epoch=$(date +%s)
    echo $(( (now_epoch - last_epoch) / 86400 ))
}

# Human-readable time since last commit
time_since_last_commit() {
    local days="$1"
    if [[ "$days" -eq 0 ]]; then
        echo "today"
    elif [[ "$days" -eq 1 ]]; then
        echo "1 day ago"
    else
        echo "${days} days ago"
    fi
}

cmd_cleanup() {
    local dry_run=false
    local force=false

    for arg in "$@"; do
        case "$arg" in
            --dry-run) dry_run=true ;;
            --force)   force=true ;;
        esac
    done

    local cleaned=()
    local stale=()
    local active=()

    # Find all main repos (directories with .git as a directory)
    while IFS= read -r git_dir; do
        local repo_path
        repo_path=$(dirname "$git_dir")
        local default_branch
        default_branch=$(detect_default_branch "$repo_path")

        # Fetch latest state of default branch for accurate merge checks
        git -C "$repo_path" fetch origin "$default_branch" &>/dev/null 2>&1 || true

        # Iterate over worktrees for this repo
        local wt_path="" wt_branch=""
        while IFS= read -r line; do
            if [[ "$line" == "worktree "* ]]; then
                wt_path="${line#worktree }"
            elif [[ "$line" == "branch "* ]]; then
                wt_branch="${line#branch refs/heads/}"

                # Skip the main repo itself
                if [[ "$wt_path" == "$repo_path" ]]; then
                    continue
                fi

                # Check if branch is merged into the default branch
                if git -C "$repo_path" merge-base --is-ancestor "$wt_branch" "$default_branch" 2>/dev/null; then
                    # Merged — clean it up
                    if [[ "$dry_run" == true ]]; then
                        cleaned+=("${wt_path} (merged into ${default_branch}) [dry-run]")
                    else
                        git -C "$repo_path" worktree remove "$wt_path" 2>/dev/null && \
                            git -C "$repo_path" worktree prune 2>/dev/null
                        cleaned+=("${wt_path} (merged into ${default_branch})")
                    fi
                else
                    # Not merged — check staleness
                    local days_old
                    days_old=$(days_since_last_commit "$repo_path" "$wt_branch")
                    local age
                    age=$(time_since_last_commit "$days_old")

                    if [[ "$days_old" -ge "$STALE_DAYS" ]]; then
                        if [[ "$force" == true ]]; then
                            if [[ "$dry_run" == true ]]; then
                                stale+=("${wt_path} (last commit: ${age}) [would force-remove]")
                            else
                                git -C "$repo_path" worktree remove --force "$wt_path" 2>/dev/null && \
                                    git -C "$repo_path" worktree prune 2>/dev/null
                                cleaned+=("${wt_path} (stale, force-removed, last commit: ${age})")
                            fi
                        else
                            stale+=("${wt_path} (last commit: ${age})")
                        fi
                    else
                        active+=("${wt_path} (last commit: ${age})")
                    fi
                fi
            fi
        done < <(git -C "$repo_path" worktree list --porcelain 2>/dev/null)
    done < <(find "$HOME/projects" -maxdepth 3 -name ".git" -type d 2>/dev/null | sort)

    # Report results
    if [[ "$dry_run" == true ]]; then
        echo ""
        echo "=== Worktree Cleanup (dry run) ==="
    else
        echo ""
        echo "=== Worktree Cleanup ==="
    fi

    echo ""
    if [[ ${#cleaned[@]} -gt 0 ]]; then
        echo "  Cleaned:"
        for entry in "${cleaned[@]}"; do
            echo "    $entry"
        done
    else
        echo "  Cleaned: (none)"
    fi

    echo ""
    if [[ ${#stale[@]} -gt 0 ]]; then
        echo "  Stale (unmerged, no activity in ${STALE_DAYS}+ days):"
        for entry in "${stale[@]}"; do
            echo "    $entry"
        done
    else
        echo "  Stale: (none)"
    fi

    echo ""
    if [[ ${#active[@]} -gt 0 ]]; then
        echo "  Active:"
        for entry in "${active[@]}"; do
            echo "    $entry"
        done
    else
        echo "  Active: (none)"
    fi

    echo ""
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
    list-worktrees)
        [[ $# -lt 2 ]] && { echo "Usage: $0 list-worktrees <repo-path>" >&2; exit 1; }
        cmd_list_worktrees "$2"
        ;;
    cleanup)
        shift
        cmd_cleanup "$@"
        ;;
    *)
        echo "Usage: $0 {create|remove|list-repos|list-worktrees|cleanup}" >&2
        exit 1
        ;;
esac
