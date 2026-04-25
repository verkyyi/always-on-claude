#!/bin/bash

normalize_code_agent() {
    case "${1:-}" in
        codex) echo "codex" ;;
        claude|"") echo "claude" ;;
        *) echo "claude" ;;
    esac
}

next_code_agent() {
    local agent
    agent=$(normalize_code_agent "${1:-${CODE_AGENT:-${DEFAULT_CODE_AGENT:-claude}}}")
    if [[ "$agent" == "codex" ]]; then
        echo "claude"
    else
        echo "codex"
    fi
}

persist_default_code_agent() {
    local agent profile tmp
    agent=$(normalize_code_agent "${1:-claude}")
    profile="$HOME/.bash_profile"

    touch "$profile"

    tmp=$(mktemp)
    awk -v agent="$agent" '
        BEGIN {
            updated = 0
            comment = "# Default coding assistant for the workspace picker"
            export_line = "export DEFAULT_CODE_AGENT=\"" agent "\""
        }
        /^export DEFAULT_CODE_AGENT=/ {
            if (!updated) {
                print export_line
                updated = 1
            }
            next
        }
        { print }
        END {
            if (!updated) {
                if (NR > 0) {
                    print ""
                }
                print comment
                print export_line
            }
        }
    ' "$profile" > "$tmp"
    cat "$tmp" > "$profile"
    rm -f "$tmp"

    DEFAULT_CODE_AGENT="$agent"
    CODE_AGENT="$agent"
    export DEFAULT_CODE_AGENT CODE_AGENT
}

toggle_code_agent() {
    local next_agent
    next_agent=$(next_code_agent "${CODE_AGENT:-${DEFAULT_CODE_AGENT:-claude}}")
    persist_default_code_agent "$next_agent"
    echo ""
    echo "  Default agent set to: $CODE_AGENT"
    echo ""
}

all_code_agent_session_pattern() {
    echo '^(claude|codex)-'
}

menu_session_pattern() {
    all_code_agent_session_pattern
}

code_agent_session_name() {
    local path="$1"
    local agent
    agent=$(normalize_code_agent "${CODE_AGENT:-${DEFAULT_CODE_AGENT:-claude}}")
    echo "${agent}-$(basename "$path" | tr './:' '-')"
}

total_memory_mb() {
    if [[ -f /proc/meminfo ]]; then
        awk '/MemTotal/ {printf "%.0f\n", $2/1024}' /proc/meminfo
    elif command -v sysctl &>/dev/null; then
        sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f\n", $1/1024/1024}'
    else
        echo 4096
    fi
}

count_sessions() {
    tmux list-sessions -F '#{session_name}' 2>/dev/null \
        | grep -Ec "$(all_code_agent_session_pattern)" || true
}

get_max_sessions() {
    if [[ -n "${MAX_SESSIONS:-}" ]]; then
        echo "$MAX_SESSIONS"
        return
    fi

    local total_mem_mb cpus mem_based max
    total_mem_mb=$(total_memory_mb)
    cpus=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
    mem_based=$(( (total_mem_mb - 512) / 650 ))
    [[ $mem_based -lt 1 ]] && mem_based=1

    max=$(( mem_based < cpus ? mem_based : cpus ))
    [[ $max -lt 1 ]] && max=1
    echo "$max"
}

tmux_detach_hint() {
    local prefix pretty
    prefix=$(tmux show-option -gv prefix 2>/dev/null || echo "C-b")
    pretty=$(echo "$prefix" | sed 's/C-/Ctrl-/')
    echo "${pretty} d"
}

check_session_limit() {
    local session_name="$1"
    if tmux has-session -t "$session_name" 2>/dev/null; then
        return 0
    fi

    local current max
    current=$(count_sessions)
    max=$(get_max_sessions)
    if [[ $current -ge $max ]]; then
        echo ""
        echo "  Session limit reached ($current/$max)."
        echo "  Each coding session uses ~650 MB — more sessions risk OOM."
        echo ""
        echo "  Options:"
        echo "    - Re-attach to an existing session (select it from the menu)"
        echo "    - Exit a running session ($(tmux_detach_hint) to detach, then /exit inside it)"
        echo ""
        return 1
    fi
    return 0
}

normalize_discovered_path() {
    local path="$1"
    if [[ "$path" == /private/* && -e "${path#/private}" ]]; then
        echo "${path#/private}"
    else
        echo "$path"
    fi
}

discover_entries() {
    entries=()
    local repo_dirs=()
    if command -v mapfile >/dev/null 2>&1; then
        mapfile -t repo_dirs < <(find "$PROJECTS_DIR" -maxdepth 3 -name ".git" -type d 2>/dev/null | sort)
    else
        local repo_dir
        while IFS= read -r repo_dir; do
            [[ -n "$repo_dir" ]] && repo_dirs+=("$repo_dir")
        done < <(find "$PROJECTS_DIR" -maxdepth 3 -name ".git" -type d 2>/dev/null | sort)
    fi

    [[ ${#repo_dirs[@]} -eq 0 ]] && return

    local tmpdir
    tmpdir=$(mktemp -d)
    for i in "${!repo_dirs[@]}"; do
        local dir
        dir=$(normalize_discovered_path "$(dirname "${repo_dirs[$i]}")")
        (
            branch=$(git -C "$dir" branch --show-current 2>/dev/null || echo "unknown")
            echo "$branch" > "$tmpdir/${i}.branch"
            git -C "$dir" worktree list --porcelain 2>/dev/null > "$tmpdir/${i}.worktrees" || true
        ) &
    done
    wait

    for i in "${!repo_dirs[@]}"; do
        local dir branch repo_name
        dir=$(normalize_discovered_path "$(dirname "${repo_dirs[$i]}")")
        branch=$(cat "$tmpdir/${i}.branch")
        repo_name=$(basename "$dir")

        entries+=("${repo_name}|${branch}|${dir}|none|0")

        local wt_path="" wt_branch=""
        while IFS= read -r line; do
            if [[ "$line" == "worktree "* ]]; then
                wt_path=$(normalize_discovered_path "${line#worktree }")
                wt_branch=""
            elif [[ "$line" == "branch "* ]]; then
                wt_branch="${line#branch refs/heads/}"
            elif [[ -z "$line" ]]; then
                if [[ "$wt_path" != "$dir" && -n "$wt_branch" ]]; then
                    entries+=("${repo_name}|${wt_branch}|${wt_path}|none|0")
                fi
                wt_path=""
                wt_branch=""
            fi
        done < <(cat "$tmpdir/${i}.worktrees"; echo)
    done

    rm -rf "$tmpdir"
}

get_sessions() {
    session_names=()
    session_states=()
    session_activities=()

    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local name attached activity
        read -r name attached activity <<< "$line"

        [[ "$name" =~ $(menu_session_pattern) ]] || continue

        session_names+=("$name")
        if [[ "$attached" -gt 0 ]]; then
            session_states+=("attached")
        else
            session_states+=("idle")
        fi
        session_activities+=("$activity")
    done < <(tmux list-sessions -F '#{session_name} #{session_attached} #{session_activity}' 2>/dev/null || true)
}

match_sessions() {
    project_entries=()
    orphaned_sessions=()

    for ei in "${!entries[@]}"; do
        IFS='|' read -r repo_name branch path _state _activity <<< "${entries[$ei]}"
        local exists=false
        local pi
        for pi in "${!project_entries[@]}"; do
            IFS='|' read -r project_name _main_branch _main_path _selected_branch _selected_path _ _selected_activity <<< "${project_entries[$pi]}"
            if [[ "$project_name" == "$repo_name" ]]; then
                exists=true
                break
            fi
        done

        if [[ "$exists" == false ]]; then
            project_entries+=("${repo_name}|${branch}|${path}|${branch}|${path}|none|0")
        fi
    done

    for si in "${!session_names[@]}"; do
        local sname="${session_names[$si]}"
        local sstate="${session_states[$si]}"
        local sactivity="${session_activities[$si]}"
        local found=false

        for ei in "${!entries[@]}"; do
            IFS='|' read -r repo_name branch path _state _activity <<< "${entries[$ei]}"
            local expected_session
            expected_session=$(code_agent_session_name "$path")

            if [[ "$sname" == "$expected_session" ]]; then
                local pi
                for pi in "${!project_entries[@]}"; do
                    IFS='|' read -r project_name _main_branch _main_path _selected_branch _selected_path selected_state selected_activity <<< "${project_entries[$pi]}"
                    [[ "$project_name" == "$repo_name" ]] || continue
                    if [[ "$sactivity" -gt "$selected_activity" ]]; then
                        project_entries[$pi]="${project_name}|${_main_branch}|${_main_path}|${branch}|${path}|${sstate}|${sactivity}"
                    fi
                    break
                done
                found=true
                break
            fi
        done

        if [[ "$found" == false ]]; then
            orphaned_sessions+=("${sname}|${sstate}|${sactivity}")
        fi
    done
}

compute_default() {
    default_idx=0

    [[ ${#project_entries[@]} -eq 0 ]] && return

    local best_idx=-1
    local best_activity=0

    for i in "${!project_entries[@]}"; do
        IFS='|' read -r _ _ _ _ _ state activity <<< "${project_entries[$i]}"
        if [[ "$state" == "idle" && "$activity" -gt "$best_activity" ]]; then
            best_activity="$activity"
            best_idx=$i
        fi
    done

    if [[ $best_idx -lt 0 ]]; then
        for i in "${!project_entries[@]}"; do
            IFS='|' read -r _ _ _ _ _ state activity <<< "${project_entries[$i]}"
            if [[ "$state" == "attached" && "$activity" -gt "$best_activity" ]]; then
                best_activity="$activity"
                best_idx=$i
            fi
        done
    fi

    if [[ $best_idx -ge 0 ]]; then
        default_idx=$best_idx
    fi
}

menu_footer_actions() {
    echo "${MENU_ACTIONS:-}"
}

show_menu() {
    local idx=1
    local next_agent footer_actions
    next_agent=$(next_code_agent "${CODE_AGENT:-${DEFAULT_CODE_AGENT:-claude}}")
    footer_actions=$(menu_footer_actions)

    echo ""

    if [[ ${#project_entries[@]} -eq 0 ]]; then
        echo "  (no repos — press m to clone)"
    else
        for i in "${!project_entries[@]}"; do
            IFS='|' read -r repo_name main_branch _main_path selected_branch _selected_path state _activity <<< "${project_entries[$i]}"
            local marker=""
            if [[ "$state" == "idle" ]]; then
                marker="  active"
            elif [[ "$state" == "attached" ]]; then
                marker="  attached"
            fi

            if [[ "$state" == "none" ]]; then
                selected_branch="$main_branch"
            fi

            echo "  [${idx}] ${repo_name}  ${selected_branch}${marker}"
            ((idx++))
        done
    fi

    if [[ ${#orphaned_sessions[@]} -gt 0 ]]; then
        echo ""
        echo "  sessions"
        for os in "${orphaned_sessions[@]}"; do
            IFS='|' read -r sname sstate _ <<< "$os"
            local omarker=""
            [[ "$sstate" == "attached" ]] && omarker="  attached"
            [[ "$sstate" == "idle" ]] && omarker="  active"
            echo "  [${idx}] ${sname}${omarker}"
            ((idx++))
        done
    fi

    echo ""
    if [[ ${#project_entries[@]} -eq 0 ]]; then
        echo "  Enter=m  agent=${CODE_AGENT}  t=toggle->${next_agent}  m=manage${footer_actions:+  ${footer_actions}}"
    else
        local default_display=$(( default_idx + 1 ))
        echo "  Enter=${default_display}  agent=${CODE_AGENT}  t=toggle->${next_agent}  m=manage${footer_actions:+  ${footer_actions}}"
    fi
    echo ""
}

prepare_project_launch() {
    :
}

prepare_manager_launch() {
    :
}

select_entry() {
    local idx="$1"

    if [[ $idx -lt ${#project_entries[@]} ]]; then
        IFS='|' read -r _ _main_branch main_path _selected_branch selected_path state _ <<< "${project_entries[$idx]}"
        local launch_path="$main_path"
        local session_name=""

        if [[ "$state" == "idle" || "$state" == "attached" ]]; then
            session_name=$(code_agent_session_name "$selected_path")
        fi

        if [[ "$state" == "idle" || "$state" == "attached" ]]; then
            echo "  -> $session_name"
            echo ""
            tmux attach-session -t "$session_name"
        else
            prepare_project_launch || return 1
            launch "$launch_path" || return 1
        fi
    else
        local oi=$(( idx - ${#project_entries[@]} ))
        IFS='|' read -r sname _ _ <<< "${orphaned_sessions[$oi]}"
        echo "  -> $sname"
        echo ""
        tmux attach-session -t "$sname"
    fi
}

handle_extra_choice() {
    return 1
}

before_picker_loop() {
    :
}

run_picker_loop() {
    before_picker_loop

    while true; do
        discover_entries
        get_sessions
        match_sessions
        compute_default
        show_menu

        read -r -p "  > " choice || true

        if [[ "$choice" == "m" ]]; then
            prepare_manager_launch || continue
            launch_manager "$MANAGER_TARGET" || true
            continue
        elif [[ "$choice" == "t" ]]; then
            toggle_code_agent
            continue
        elif handle_extra_choice "$choice"; then
            continue
        elif [[ -z "$choice" ]]; then
            if [[ ${#project_entries[@]} -eq 0 ]]; then
                prepare_manager_launch || continue
                launch_manager "$MANAGER_TARGET" || true
            else
                select_entry "$default_idx" || true
            fi
            continue
        elif [[ "$choice" =~ ^[0-9]+$ ]]; then
            idx=$(( choice - 1 ))
            total=$(( ${#project_entries[@]} + ${#orphaned_sessions[@]} ))
            if [[ $idx -ge 0 && $idx -lt $total ]]; then
                select_entry "$idx" || true
            fi
        fi
    done
}
