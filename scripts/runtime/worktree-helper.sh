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

# Load config if available
_DEV_ENV="${DEV_ENV:-$HOME/dev-env}"
if [[ -f "$_DEV_ENV/scripts/deploy/load-config.sh" ]]; then
    # shellcheck disable=SC1091
    source "$_DEV_ENV/scripts/deploy/load-config.sh"
fi
: "${PROJECTS_DIR:=$HOME/projects}"

sanitize_branch() {
    echo "$1" | tr '/' '-'
}

normalize_path() {
    local path="$1"
    if [[ "$path" == /private/* && -e "${path#/private}" ]]; then
        echo "${path#/private}"
    else
        echo "$path"
    fi
}

project_root_aliases() {
    printf '%s\n' "$(normalize_path "$PROJECTS_DIR")"
    if [[ "$(normalize_path "$PROJECTS_DIR")" != "/home/dev/projects" ]]; then
        printf '%s\n' "/home/dev/projects"
    fi
}

worktree_path_aliases() {
    local worktree_path="$1"
    local normalized root suffix seen=""
    normalized=$(normalize_path "$worktree_path")

    while IFS= read -r root; do
        [[ -n "$root" ]] || continue
        if [[ "$normalized" == "$root"* ]]; then
            suffix="${normalized#"$root"}"
            :
        else
            local current_root
            current_root=$(dirname "${normalized%%--*}")
            if [[ "$current_root" == "$root" ]]; then
                suffix="${normalized#"$current_root"}"
            else
                continue
            fi
        fi

        local candidate="${root}${suffix}"
        if [[ "$seen" != *"|$candidate|"* ]]; then
            printf '%s\n' "$candidate"
            seen="${seen}|$candidate|"
        fi
    done < <(project_root_aliases)
}

cleanup_lingering_worktree_dir() {
    local worktree_path="$1"
    local candidate

    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        [[ -e "$candidate" ]] || continue

        if [[ -f "$candidate/.git" ]]; then
            local gitdir
            gitdir=$(sed -n 's/^gitdir: //p' "$candidate/.git" 2>/dev/null || true)
            if [[ -z "$gitdir" || ! -e "$gitdir" ]]; then
                rm -rf "$candidate"
            fi
        fi
    done < <(worktree_path_aliases "$worktree_path")
}

remote_default_branch() {
    local repo_path="$1"
    local symbolic_ref
    symbolic_ref=$(git -C "$repo_path" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    if [[ -n "$symbolic_ref" ]]; then
        echo "${symbolic_ref#origin/}"
        return 0
    fi
    return 1
}

branch_exists() {
    local repo_path="$1" branch="$2"
    git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch"
}

remote_branch_exists() {
    local repo_path="$1" branch="$2"
    git -C "$repo_path" show-ref --verify --quiet "refs/remotes/origin/$branch"
}

ensure_local_branch_tracks_remote() {
    local repo_path="$1" branch="$2"

    if remote_branch_exists "$repo_path" "$branch"; then
        git -C "$repo_path" checkout -B "$branch" "origin/$branch" >/dev/null 2>&1
    elif branch_exists "$repo_path" "$branch"; then
        git -C "$repo_path" checkout -f "$branch" >/dev/null 2>&1
    else
        git -C "$repo_path" checkout -B "$branch" >/dev/null 2>&1
    fi
}

generate_session_slug() {
    date +%Y%m%d-%H%M%S
}

repo_has_dirty_changes() {
    local repo_path="$1"
    [[ -n "$(git -C "$repo_path" status --porcelain 2>/dev/null || true)" ]]
}

worktree_has_dirty_changes() {
    local worktree_path="$1"
    [[ -n "$(git -C "$worktree_path" status --porcelain 2>/dev/null || true)" ]]
}

cmd_create() {
    local repo_path="$1" branch="$2"
    repo_path=$(normalize_path "$repo_path")
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
    worktree_path=$(normalize_path "$worktree_path")

    if [[ ! -f "$worktree_path/.git" ]]; then
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
    local dir branch
    # Find all .git entries (directories = repos, files = worktrees)
    while IFS= read -r git_entry; do
        dir=$(dirname "$git_entry")

        if [[ -d "$git_entry" ]]; then
            # Regular repo — .git is a directory
            branch=$(git -C "$dir" branch --show-current 2>/dev/null || echo "unknown")
            echo "REPO|${dir}|${branch}"
        elif [[ -f "$git_entry" ]]; then
            # Worktree — .git is a file
            branch=$(git -C "$dir" branch --show-current 2>/dev/null || echo "unknown")
            echo "WORKTREE|${dir}|${branch}"
        fi
    done < <(find "$PROJECTS_DIR" -maxdepth 3 -name ".git" \( -type d -o -type f \) 2>/dev/null | sort)
}

cmd_list_worktrees() {
    local repo_path="$1"
    repo_path=$(normalize_path "$repo_path")

    if [[ ! -d "$repo_path/.git" ]]; then
        echo "Error: not a git repo: $repo_path" >&2
        exit 1
    fi

    # git worktree list shows main + worktrees; skip the main repo itself
    local wt_path="" wt_branch=""
    while IFS= read -r line; do
        if [[ "$line" == "worktree "* ]]; then
            wt_path=$(normalize_path "${line#worktree }")
            wt_branch=""  # Reset; will be set by "branch" line or left empty for detached HEAD
        elif [[ "$line" == "branch "* ]]; then
            wt_branch="${line#branch refs/heads/}"
        elif [[ -z "$line" ]]; then
            # Blank line = end of a worktree block
            # Skip the main repo itself and detached HEAD worktrees
            if [[ "$wt_path" != "$repo_path" && -n "$wt_branch" ]]; then
                echo "${wt_path}|${wt_branch}"
            fi
            wt_path=""
            wt_branch=""
        fi
    done < <(git -C "$repo_path" worktree list --porcelain 2>/dev/null; echo)
}

STALE_DAYS=7

# Detect the default branch (main or master) for a given repo
detect_default_branch() {
    local repo_path="$1"
    repo_path=$(normalize_path "$repo_path")
    if remote_default_branch "$repo_path"; then
        return 0
    fi
    for candidate in main master; do
        if git -C "$repo_path" rev-parse --verify "$candidate" &>/dev/null; then
            echo "$candidate"
            return
        fi
    done
    echo "main"
}

cmd_default_branch() {
    local repo_path="$1"
    repo_path=$(normalize_path "$repo_path")

    if [[ ! -d "$repo_path/.git" ]]; then
        echo "Error: not a git repo: $repo_path" >&2
        exit 1
    fi

    detect_default_branch "$repo_path"
}

cmd_sync_repo() {
    local repo_path="$1"
    repo_path=$(normalize_path "$repo_path")

    if [[ ! -d "$repo_path/.git" ]]; then
        echo "Error: not a git repo: $repo_path" >&2
        exit 1
    fi

    local default_branch upstream_ref
    default_branch=$(detect_default_branch "$repo_path")

    git -C "$repo_path" fetch --prune origin >/dev/null 2>&1 || true

    ensure_local_branch_tracks_remote "$repo_path" "$default_branch"

    upstream_ref="$default_branch"
    if remote_branch_exists "$repo_path" "$default_branch"; then
        upstream_ref="origin/$default_branch"
    fi

    git -C "$repo_path" reset --hard "$upstream_ref" >/dev/null 2>&1
    git -C "$repo_path" clean -fd >/dev/null 2>&1
    git -C "$repo_path" worktree prune >/dev/null 2>&1 || true

    echo "${repo_path}|${default_branch}"
}

cmd_create_session_worktree() {
    local repo_path="$1"
    repo_path=$(normalize_path "$repo_path")

    if [[ ! -d "$repo_path/.git" ]]; then
        echo "Error: not a git repo: $repo_path" >&2
        exit 1
    fi

    local default_branch base_ref slug branch worktree_path suffix=0
    default_branch=$(detect_default_branch "$repo_path")
    if remote_branch_exists "$repo_path" "$default_branch"; then
        base_ref="origin/$default_branch"
    else
        base_ref="$default_branch"
    fi

    while true; do
        slug=$(generate_session_slug)
        if [[ $suffix -gt 0 ]]; then
            slug="${slug}-${suffix}"
        fi
        branch="sess/${slug}"
        worktree_path="${repo_path}--$(sanitize_branch "$branch")"

        if [[ ! -e "$worktree_path" ]] && ! branch_exists "$repo_path" "$branch"; then
            break
        fi
        suffix=$((suffix + 1))
        sleep 1
    done

    git -C "$repo_path" worktree add -b "$branch" "$worktree_path" "$base_ref" >/dev/null 2>&1

    echo "${worktree_path}|${branch}|${default_branch}"
}

cmd_recover_dirty_repo() {
    local repo_path="$1"
    repo_path=$(normalize_path "$repo_path")

    if [[ ! -d "$repo_path/.git" ]]; then
        echo "Error: not a git repo: $repo_path" >&2
        exit 1
    fi

    if ! repo_has_dirty_changes "$repo_path"; then
        echo "Error: repo is already clean: $repo_path" >&2
        exit 1
    fi

    local current_branch sanitized_base slug branch worktree_path stash_message stash_ref
    current_branch=$(git -C "$repo_path" branch --show-current 2>/dev/null || true)
    sanitized_base=$(sanitize_branch "${current_branch:-recovery}")
    slug=$(generate_session_slug)
    branch="sess-recover/${sanitized_base}-${slug}"
    worktree_path="${repo_path}--$(sanitize_branch "$branch")"

    stash_message="aoc-recover-${slug}"
    git -C "$repo_path" stash push -u -m "$stash_message" >/dev/null 2>&1
    stash_ref=$(git -C "$repo_path" rev-parse -q --verify 'stash@{0}' 2>/dev/null || true)
    if [[ -z "$stash_ref" ]]; then
        echo "Error: failed to stash dirty repo state: $repo_path" >&2
        exit 1
    fi

    if ! git -C "$repo_path" worktree add -b "$branch" "$worktree_path" HEAD >/dev/null 2>&1; then
        echo "Error: failed to create recovery worktree: $worktree_path" >&2
        exit 1
    fi

    if ! git -C "$worktree_path" stash apply "$stash_ref" >/dev/null 2>&1; then
        echo "Error: failed to apply recovered changes in worktree: $worktree_path" >&2
        exit 1
    fi

    git -C "$worktree_path" stash drop "$stash_ref" >/dev/null 2>&1 || true

    echo "${worktree_path}|${branch}"
}

# Get the number of days since the last commit on a branch
days_since_last_commit() {
    local repo_path="$1" branch="$2"
    local last_epoch
    last_epoch=$(git -C "$repo_path" log -1 --format='%ct' "$branch" 2>/dev/null || true)
    # Empty output means no commits found — treat as active (0 days), not ancient
    if [[ -z "$last_epoch" || "$last_epoch" -le 0 ]] 2>/dev/null; then
        echo "0"
        return
    fi
    local now_epoch
    now_epoch=$(date +%s)
    echo $(( (now_epoch - last_epoch) / 86400 ))
}

branch_has_unique_commits() {
    local repo_path="$1" branch="$2" default_ref="$3"
    local ahead_count
    ahead_count=$(git -C "$repo_path" rev-list --count "${default_ref}..${branch}" 2>/dev/null || echo "0")
    [[ "$ahead_count" -gt 0 ]]
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

record_unique_cleanup_entry() {
    local bucket="$1" entry="$2"
    local seen_var="seen_${bucket}"
    local current_seen
    current_seen=$(eval "printf '%s' \"\${$seen_var:-}\"")
    if [[ "$current_seen" == *"|$entry|"* ]]; then
        return 0
    fi
    eval "${bucket}+=(\"\$entry\")"
    eval "$seen_var=\"\${$seen_var:-}|$entry|\""
}

cmd_cleanup() {
    local dry_run=false
    local force=false
    local quiet=false
    local keep_paths=()
    local scope_repo=""

    for arg in "$@"; do
        case "$arg" in
            --dry-run) dry_run=true ;;
            --force)   force=true ;;
            --quiet)   quiet=true ;;
        esac
    done

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|--force|--quiet)
                shift
                ;;
            --keep-path)
                keep_paths+=("$(normalize_path "$2")")
                shift 2
                ;;
            --repo)
                scope_repo=$(normalize_path "$2")
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    local cleaned=()
    local stale=()
    local active=()
    local dirty_merged=()
    local orphans=()
    local readonly_repos=()
    # shellcheck disable=SC2034  # accessed indirectly via "seen_${bucket}" in record_unique_cleanup_entry
    local seen_cleaned=""
    # shellcheck disable=SC2034
    local seen_stale=""
    # shellcheck disable=SC2034
    local seen_active=""
    # shellcheck disable=SC2034
    local seen_dirty_merged=""
    # shellcheck disable=SC2034
    local seen_orphans=""
    # shellcheck disable=SC2034
    local seen_readonly_repos=""
    local repo_glob_root="$HOME/projects"

    if [[ -n "$scope_repo" ]]; then
        repo_glob_root="$scope_repo"
    fi

    # --- Pre-prune pass ---
    # Walk all repos and run `git worktree prune` to clear registered-but-missing
    # worktree entries before the main scan. Skip read-only mounts (e.g. virtiofs
    # ro mount of dev-env inside the container) so we don't churn on errors.
    #
    # Loop FD 3 holds the find pipe and FD 4 holds the inner worktree-list pipe.
    # Without this isolation, child processes in the loop body inherit FD 0 from
    # the loop redirection, and any one that reads stdin (e.g. git fetch's
    # askpass probe) silently consumes the next path off the find pipe — so the
    # next repo is skipped without any error. See test_cleanup_processes_all_repos_when_inner_git_reads_stdin.
    local _registered_worktrees="|"
    while IFS= read -r git_dir <&3; do
        local _repo_path
        _repo_path=$(normalize_path "$(dirname "$git_dir")")
        if [[ -n "$scope_repo" && "$_repo_path" != "$scope_repo" ]]; then
            continue
        fi
        if [[ ! -w "$git_dir" ]]; then
            record_unique_cleanup_entry readonly_repos "${_repo_path} (read-only mount, prune from host)"
            continue
        fi
        git -C "$_repo_path" worktree prune 2>/dev/null || true
        # While we're here, build a set of all currently-registered worktree paths
        # for the orphan-sibling scan below.
        while IFS= read -r _wt_line <&4; do
            if [[ "$_wt_line" == "worktree "* ]]; then
                local _wt
                _wt=$(normalize_path "${_wt_line#worktree }")
                _registered_worktrees="${_registered_worktrees}${_wt}|"
            fi
        done 4< <(git -C "$_repo_path" worktree list --porcelain 2>/dev/null)
    done 3< <(find "$repo_glob_root" -maxdepth 3 -name ".git" -type d 2>/dev/null | sort)

    # Find all main repos (directories with .git as a directory)
    while IFS= read -r git_dir <&3; do
        local repo_path
        repo_path=$(normalize_path "$(dirname "$git_dir")")
        if [[ -n "$scope_repo" && "$repo_path" != "$scope_repo" ]]; then
            continue
        fi
        local default_branch
        default_branch=$(detect_default_branch "$repo_path")

        # Fetch latest state of default branch for accurate merge checks.
        git -C "$repo_path" fetch origin "$default_branch" &>/dev/null || true

        # Iterate over worktrees for this repo
        local wt_path="" wt_branch=""
        while IFS= read -r line <&4; do
            if [[ "$line" == "worktree "* ]]; then
                wt_path=$(normalize_path "${line#worktree }")
                wt_branch=""  # Reset; will be set by "branch" line or left empty for detached HEAD
            elif [[ "$line" == "branch "* ]]; then
                wt_branch="${line#branch refs/heads/}"
            elif [[ -z "$line" ]]; then
                # Blank line = end of a worktree block

                # Skip the main repo itself
                if [[ "$wt_path" == "$repo_path" ]]; then
                    continue
                fi

                # Skip detached HEAD worktrees (no branch to check)
                if [[ -z "$wt_branch" ]]; then
                    record_unique_cleanup_entry active "${wt_path} (detached HEAD)"
                    continue
                fi

                local keep
                for keep in "${keep_paths[@]:-}"; do
                    if [[ "$wt_path" == "$keep" ]]; then
                        record_unique_cleanup_entry active "${wt_path} (active tmux session)"
                        wt_path=""
                        wt_branch=""
                        continue 2
                    fi
                done

                local default_ref="origin/$default_branch"
                if ! remote_branch_exists "$repo_path" "$default_branch"; then
                    default_ref="$default_branch"
                fi

                local _has_unique=true
                if ! branch_has_unique_commits "$repo_path" "$wt_branch" "$default_ref"; then
                    _has_unique=false
                fi

                # Dirty worktrees: surface but never auto-remove. If the branch
                # has no unique commits beyond default (likely merged), flag it
                # for review separately so the user knows it can probably go.
                if worktree_has_dirty_changes "$wt_path"; then
                    if [[ "$_has_unique" == false ]]; then
                        record_unique_cleanup_entry dirty_merged "${wt_path} (merged, but has local edits — review)"
                    else
                        record_unique_cleanup_entry active "${wt_path} (local edits)"
                    fi
                    wt_path=""
                    wt_branch=""
                    continue
                fi

                # Remove worktrees that contribute no unique commits beyond default.
                # This covers merged branches and untouched branches that simply lag main.
                if [[ "$_has_unique" == false ]]; then
                    if [[ "$dry_run" == true ]]; then
                        record_unique_cleanup_entry cleaned "${wt_path} (no unique commits beyond ${default_branch}) [dry-run]"
                    else
                        git -C "$repo_path" worktree remove "$wt_path" 2>/dev/null || true
                        git -C "$repo_path" worktree prune 2>/dev/null || true
                        cleanup_lingering_worktree_dir "$wt_path"
                        if [[ -e "$wt_path" ]]; then
                            record_unique_cleanup_entry active "${wt_path} (cleanup failed)"
                        else
                            record_unique_cleanup_entry cleaned "${wt_path} (no unique commits beyond ${default_branch})"
                        fi
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
                                record_unique_cleanup_entry stale "${wt_path} (last commit: ${age}) [would force-remove]"
                            else
                                git -C "$repo_path" worktree remove --force "$wt_path" 2>/dev/null || true
                                git -C "$repo_path" worktree prune 2>/dev/null || true
                                record_unique_cleanup_entry cleaned "${wt_path} (stale, force-removed, last commit: ${age})"
                            fi
                        else
                            record_unique_cleanup_entry stale "${wt_path} (last commit: ${age})"
                        fi
                    else
                        record_unique_cleanup_entry active "${wt_path} (last commit: ${age})"
                    fi
                fi
            fi
        done 4< <(git -C "$repo_path" worktree list --porcelain 2>/dev/null; echo)
    done 3< <(find "$repo_glob_root" -maxdepth 3 -name ".git" -type d 2>/dev/null | sort)

    # --- Orphan-sibling scan ---
    # Walk top-level <basename>--* sibling dirs and remove those that:
    #   - have a stale `.git` file pointing to a missing gitdir, AND
    #   - are not registered as a worktree anywhere
    # We deliberately do NOT auto-remove "empty stub" dirs (no .git at all) —
    # those can be in-progress user work; we only surface them.
    while IFS= read -r sibling <&3; do
        sibling=$(normalize_path "$sibling")
        if [[ "$_registered_worktrees" == *"|${sibling}|"* ]]; then
            continue
        fi
        if [[ -f "$sibling/.git" ]]; then
            local _gitdir
            _gitdir=$(sed -n 's/^gitdir: //p' "$sibling/.git" 2>/dev/null || true)
            if [[ -n "$_gitdir" && -e "$_gitdir" ]]; then
                # gitdir is live but worktree isn't registered — odd, leave alone.
                continue
            fi
            if [[ "$dry_run" == true ]]; then
                record_unique_cleanup_entry orphans "${sibling} (stale gitdir) [dry-run]"
            else
                rm -rf "$sibling"
                if [[ -e "$sibling" ]]; then
                    record_unique_cleanup_entry active "${sibling} (orphan removal failed)"
                else
                    record_unique_cleanup_entry orphans "${sibling} (stale gitdir, removed)"
                fi
            fi
        elif [[ ! -e "$sibling/.git" ]]; then
            # No .git at all — empty stub. Don't auto-remove; just surface.
            record_unique_cleanup_entry active "${sibling} (empty stub, not a worktree — review)"
        fi
    done 3< <(find "$repo_glob_root" -maxdepth 1 -mindepth 1 -name '*--*' -type d 2>/dev/null | sort)

    # Report results
    if [[ "$quiet" == true ]]; then
        return 0
    fi

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
    if [[ ${#dirty_merged[@]} -gt 0 ]]; then
        echo "  Dirty but merged (review):"
        for entry in "${dirty_merged[@]}"; do
            echo "    $entry"
        done
        echo ""
    fi

    if [[ ${#orphans[@]} -gt 0 ]]; then
        echo "  Orphans (stale gitdir, removed):"
        for entry in "${orphans[@]}"; do
            echo "    $entry"
        done
        echo ""
    fi

    if [[ ${#readonly_repos[@]} -gt 0 ]]; then
        echo "  Read-only repos (skipped):"
        for entry in "${readonly_repos[@]}"; do
            echo "    $entry"
        done
        echo ""
    fi

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
    default-branch)
        [[ $# -lt 2 ]] && { echo "Usage: $0 default-branch <repo-path>" >&2; exit 1; }
        cmd_default_branch "$2"
        ;;
    sync-repo)
        [[ $# -lt 2 ]] && { echo "Usage: $0 sync-repo <repo-path>" >&2; exit 1; }
        cmd_sync_repo "$2"
        ;;
    create-session-worktree)
        [[ $# -lt 2 ]] && { echo "Usage: $0 create-session-worktree <repo-path>" >&2; exit 1; }
        cmd_create_session_worktree "$2"
        ;;
    recover-dirty-repo)
        [[ $# -lt 2 ]] && { echo "Usage: $0 recover-dirty-repo <repo-path>" >&2; exit 1; }
        cmd_recover_dirty_repo "$2"
        ;;
    cleanup)
        shift
        cmd_cleanup "$@"
        ;;
    *)
        echo "Usage: $0 {create|remove|list-repos|list-worktrees|default-branch|sync-repo|create-session-worktree|recover-dirty-repo|cleanup}" >&2
        exit 1
        ;;
esac
