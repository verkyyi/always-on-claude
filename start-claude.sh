#!/bin/bash
# start-claude.sh — Auto-starts the dev container if needed,
# then presents a workspace picker and launches Claude Code
# inside a named tmux session.
#
# Called automatically from ssh-login.sh on SSH login.

set -euo pipefail

COMPOSE_DIR="$HOME/dev-env"
CONTAINER_NAME="claude-dev"

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Container not running. Starting..."
    cd "$COMPOSE_DIR" && docker compose up -d
    sleep 2

    # Fix named volume permissions (projects dir mounts as root)
    # ~/.claude is a bind mount — inherits host ownership, no fix needed
    docker compose exec -u root dev bash -c \
        "chown -R dev:dev /home/dev/projects" 2>/dev/null || true
fi

show_menu() {
    # Discover repos and worktrees via worktree-helper.sh
    mapfile -t entries < <(
        docker exec "$CONTAINER_NAME" bash -c \
            'bash /home/dev/dev-env/worktree-helper.sh list-repos 2>/dev/null' \
        | sort
    )

    # Separate repos and worktrees
    repos=()
    worktrees=()
    for entry in "${entries[@]}"; do
        IFS='|' read -r kind path branch <<< "$entry"
        case "$kind" in
            REPO)     repos+=("$path|$branch") ;;
            WORKTREE) worktrees+=("$path|$branch") ;;
        esac
    done

    # Build combined list for display (repos first, then worktrees)
    all=()
    for item in "${repos[@]+"${repos[@]}"}"; do all+=("$item"); done
    for item in "${worktrees[@]+"${worktrees[@]}"}"; do all+=("WT:$item"); done

    echo ""
    echo "  +---------------------------------+"
    echo "  |  Pick workspace:                |"

    local i=1
    for item in "${all[@]}"; do
        local display_path display_branch suffix=""
        if [[ "$item" == WT:* ]]; then
            item="${item#WT:}"
            suffix=" (worktree)"
        fi
        IFS='|' read -r display_path display_branch <<< "$item"
        local short_path="${display_path#/home/dev/}"
        local label="  |  [$i] ${short_path} (${display_branch})${suffix}"
        printf "%-37s|\n" "$label"
        ((i++))
    done

    printf "%-37s|\n" "  |  [w] New worktree"
    if [[ ${#worktrees[@]} -gt 0 ]]; then
        printf "%-37s|\n" "  |  [d] Delete worktree"
    fi
    printf "%-37s|\n" "  |  [h] ~ (home)"
    echo "  +---------------------------------+"
    echo ""
}

show_menu

while true; do
    choice=""
    read -n 1 -p "  > " choice || true
    echo ""

    # Combine repos + worktrees into a flat list for index lookup
    all_flat=()
    for item in "${repos[@]+"${repos[@]}"}"; do all_flat+=("$item"); done
    for item in "${worktrees[@]+"${worktrees[@]}"}"; do all_flat+=("$item"); done

    if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#all_flat[@]}" ]]; then
        IFS='|' read -r selected _ <<< "${all_flat[$((choice - 1))]}"
        break

    elif [[ "$choice" == "h" ]]; then
        selected="/home/dev"
        break

    elif [[ "$choice" == "w" ]]; then
        # New worktree flow: pick a repo, then enter branch name
        if [[ ${#repos[@]} -eq 0 ]]; then
            echo "  No repos found to create a worktree from."
            continue
        fi

        echo ""
        echo "  Create worktree from which repo?"
        ri=1
        for repo_entry in "${repos[@]}"; do
            IFS='|' read -r rpath rbranch <<< "$repo_entry"
            echo "  [$ri] ${rpath#/home/dev/} ($rbranch)"
            ((ri++))
        done
        echo ""
        read -n 1 -p "  repo> " repo_choice || true
        echo ""

        if [[ ! "$repo_choice" =~ ^[0-9]+$ || "$repo_choice" -lt 1 || "$repo_choice" -gt "${#repos[@]}" ]]; then
            echo "  Invalid choice."
            show_menu
            continue
        fi

        IFS='|' read -r base_repo _ <<< "${repos[$((repo_choice - 1))]}"

        echo ""
        read -r -p "  Branch name: " branch_name
        if [[ -z "$branch_name" ]]; then
            echo "  No branch name given."
            show_menu
            continue
        fi

        echo "  Creating worktree..."
        wt_result=$(docker exec "$CONTAINER_NAME" bash -c \
            "bash /home/dev/dev-env/worktree-helper.sh create '$base_repo' '$branch_name'" 2>&1) || {
            echo "  Error: $wt_result"
            show_menu
            continue
        }

        selected="$wt_result"
        echo "  Created: $selected"
        break

    elif [[ "$choice" == "d" && ${#worktrees[@]} -gt 0 ]]; then
        # Delete worktree flow
        echo ""
        echo "  Delete which worktree?"
        wi=1
        for wt_entry in "${worktrees[@]}"; do
            IFS='|' read -r wpath wbranch <<< "$wt_entry"
            echo "  [$wi] ${wpath#/home/dev/} ($wbranch)"
            ((wi++))
        done
        echo ""
        read -n 1 -p "  delete> " del_choice || true
        echo ""

        if [[ ! "$del_choice" =~ ^[0-9]+$ || "$del_choice" -lt 1 || "$del_choice" -gt "${#worktrees[@]}" ]]; then
            echo "  Invalid choice."
            show_menu
            continue
        fi

        IFS='|' read -r del_path _ <<< "${worktrees[$((del_choice - 1))]}"

        echo "  Removing worktree: $del_path"
        docker exec "$CONTAINER_NAME" bash -c \
            "bash /home/dev/dev-env/worktree-helper.sh remove '$del_path'" 2>&1 || true

        echo "  Done."
        echo ""
        show_menu
        continue

    else
        # Default: first repo, or home if none found
        if [[ ${#all_flat[@]} -gt 0 ]]; then
            IFS='|' read -r selected _ <<< "${all_flat[0]}"
        else
            selected="/home/dev"
        fi
        break
    fi
done

echo "  -> $selected"
echo ""

# Create unique tmux session name — sanitize dots/colons/slashes for tmux
session_name="claude-$(basename "$selected" | tr './:' '-')"

exec tmux new-session -A -s "$session_name" \
    "docker exec -it -w '$selected' ${CONTAINER_NAME} bash -lc 'exec claude'"
