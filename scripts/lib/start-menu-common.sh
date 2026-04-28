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

code_agent_session_name_for_agent() {
    local agent="$1" path="$2"
    agent=$(normalize_code_agent "$agent")
    echo "${agent}-$(basename "$path" | tr './:' '-')"
}

code_agent_session_name() {
    local path="$1"
    code_agent_session_name_for_agent "${CODE_AGENT:-${DEFAULT_CODE_AGENT:-claude}}" "$path"
}

session_agent_from_name() {
    case "${1:-}" in
        claude-*) echo "claude" ;;
        codex-*) echo "codex" ;;
        *) echo "" ;;
    esac
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

attach_tmux_session() {
    local session_name="$1"

    if [[ "${AOC_SINGLE_TMUX_CLIENT:-1}" == "1" ]]; then
        tmux detach-client -s "$session_name" 2>/dev/null || true
    fi

    tmux attach-session -t "$session_name"
}

new_or_attach_tmux_session() {
    local session_name="$1"
    shift

    if tmux has-session -t "$session_name" 2>/dev/null; then
        attach_tmux_session "$session_name"
        return 0
    fi

    tmux new-session -d -s "$session_name" "$@"

    [[ -n "${AOC_SESSION_PATH:-}" ]] && tmux set-option -t "$session_name" -q @aoc_path "$AOC_SESSION_PATH"
    [[ -n "${AOC_SESSION_REPO:-}" ]] && tmux set-option -t "$session_name" -q @aoc_repo "$AOC_SESSION_REPO"
    [[ -n "${AOC_SESSION_BRANCH:-}" ]] && tmux set-option -t "$session_name" -q @aoc_branch "$AOC_SESSION_BRANCH"
    [[ -n "${AOC_SESSION_NOTE:-}" ]] && tmux set-option -t "$session_name" -q @aoc_note "$AOC_SESSION_NOTE"

    attach_tmux_session "$session_name"
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

project_repo_paths() {
    local repo_dirs=()
    if command -v mapfile >/dev/null 2>&1; then
        mapfile -t repo_dirs < <(find "$PROJECTS_DIR" -maxdepth 3 -name ".git" -type d 2>/dev/null | sort)
    else
        local repo_dir
        while IFS= read -r repo_dir; do
            [[ -n "$repo_dir" ]] && repo_dirs+=("$repo_dir")
        done < <(find "$PROJECTS_DIR" -maxdepth 3 -name ".git" -type d 2>/dev/null | sort)
    fi

    [[ ${#repo_dirs[@]} -eq 0 ]] && return 0
    printf '%s\n' "${repo_dirs[@]}"
}

detect_project_default_branch() {
    local repo_path="$1"
    local symbolic_ref
    symbolic_ref=$(git -C "$repo_path" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    if [[ -n "$symbolic_ref" ]]; then
        echo "${symbolic_ref#origin/}"
        return 0
    fi

    for candidate in main master; do
        if git -C "$repo_path" rev-parse --verify "$candidate" &>/dev/null; then
            echo "$candidate"
            return 0
        fi
    done

    git -C "$repo_path" branch --show-current 2>/dev/null || echo "main"
}

discover_entries() {
    entries=()
    project_entries=()
    local repo_dirs=()

    while IFS= read -r repo_dir; do
        [[ -n "$repo_dir" ]] && repo_dirs+=("$repo_dir")
    done < <(project_repo_paths)

    [[ ${#repo_dirs[@]} -eq 0 ]] && return

    local tmpdir
    tmpdir=$(mktemp -d)
    for i in "${!repo_dirs[@]}"; do
        local dir
        dir=$(normalize_discovered_path "$(dirname "${repo_dirs[$i]}")")
        (
            local default_branch
            default_branch=$(detect_project_default_branch "$dir")
            echo "$default_branch" > "$tmpdir/${i}.branch"
            git -C "$dir" worktree list --porcelain 2>/dev/null > "$tmpdir/${i}.worktrees" || true
        ) &
    done
    wait

    for i in "${!repo_dirs[@]}"; do
        local dir branch repo_name
        dir=$(normalize_discovered_path "$(dirname "${repo_dirs[$i]}")")
        branch=$(cat "$tmpdir/${i}.branch")
        repo_name=$(basename "$dir")

        local repo_warning="" repo_refreshing=""
        if [[ "${PROJECT_SYNC_WARNINGS+x}" == "x" && ${#PROJECT_SYNC_WARNINGS[@]} -gt 0 ]]; then
            local warning_entry warning_path warning_message
            for warning_entry in "${PROJECT_SYNC_WARNINGS[@]}"; do
                IFS='|' read -r warning_path warning_message <<< "$warning_entry"
                if [[ "$warning_path" == "$dir" ]]; then
                    repo_warning="$warning_message"
                    break
                fi
            done
        fi

        if [[ "${PROJECT_SYNC_REFRESHING+x}" == "x" && ${#PROJECT_SYNC_REFRESHING[@]} -gt 0 ]]; then
            local refreshing_path
            for refreshing_path in "${PROJECT_SYNC_REFRESHING[@]}"; do
                if [[ "$refreshing_path" == "$dir" ]]; then
                    repo_refreshing="refreshing"
                    break
                fi
            done
        fi

        project_entries+=("${repo_name}|${branch}|${dir}|repo|${repo_warning}|${repo_refreshing}")
        entries+=("${repo_name}|${branch}|${dir}|repo")

        local wt_path="" wt_branch=""
        while IFS= read -r line; do
            if [[ "$line" == "worktree "* ]]; then
                wt_path=$(normalize_discovered_path "${line#worktree }")
                wt_branch=""
            elif [[ "$line" == "branch "* ]]; then
                wt_branch="${line#branch refs/heads/}"
            elif [[ -z "$line" ]]; then
                if [[ "$wt_path" != "$dir" && -n "$wt_branch" ]]; then
                    entries+=("${repo_name}|${wt_branch}|${wt_path}|worktree")
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
    session_paths=()
    session_repos=()
    session_branches=()
    session_notes=()

    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local name attached activity path repo_name branch note
        IFS=$'\t' read -r name attached activity path repo_name branch note <<< "$line"

        [[ "$name" =~ $(menu_session_pattern) ]] || continue

        session_names+=("$name")
        if [[ "$attached" -gt 0 ]]; then
            session_states+=("attached")
        else
            session_states+=("idle")
        fi
        session_activities+=("$activity")
        session_paths+=("$path")
        session_repos+=("$repo_name")
        session_branches+=("$branch")
        session_notes+=("$note")
    done < <(tmux list-sessions -F '#{session_name}'$'\t''#{session_attached}'$'\t''#{session_activity}'$'\t''#{@aoc_path}'$'\t''#{@aoc_repo}'$'\t''#{@aoc_branch}'$'\t''#{@aoc_note}' 2>/dev/null || true)
}

find_entry_for_session() {
    local session_name="$1" session_path="$2" session_repo="$3" session_branch="$4"
    local ei

    if [[ -n "$session_path" ]]; then
        for ei in "${!entries[@]}"; do
            IFS='|' read -r repo_name branch path _kind <<< "${entries[$ei]}"
            if [[ "$path" == "$session_path" ]]; then
                echo "${repo_name}|${branch}|${path}"
                return 0
            fi
        done
    fi

    if [[ -n "$session_repo" && -n "$session_branch" ]]; then
        for ei in "${!entries[@]}"; do
            IFS='|' read -r repo_name branch path _kind <<< "${entries[$ei]}"
            if [[ "$repo_name" == "$session_repo" && "$branch" == "$session_branch" ]]; then
                echo "${repo_name}|${branch}|${path}"
                return 0
            fi
        done
    fi

    local session_agent
    session_agent=$(session_agent_from_name "$session_name")
    for ei in "${!entries[@]}"; do
        IFS='|' read -r repo_name branch path _kind <<< "${entries[$ei]}"
        if [[ "$session_name" == "$(code_agent_session_name_for_agent "$session_agent" "$path")" ]]; then
            echo "${repo_name}|${branch}|${path}"
            return 0
        fi
    done

    return 1
}

session_display_label() {
    local repo_name="$1" branch="$2" agent="$3" fallback="$4" note="${5:-}"
    local label

    if [[ -n "$repo_name" && -n "$branch" ]]; then
        label="${repo_name}  ${branch}  ${agent}"
    elif [[ -n "$repo_name" ]]; then
        label="${repo_name}  ${agent}"
    elif [[ -n "$branch" ]]; then
        label="${branch}  ${agent}"
    else
        label="$fallback"
    fi

    if [[ -n "$note" ]]; then
        label="${label}  :: ${note}"
    fi

    echo "$label"
}

session_sort_key() {
    local repo_name="$1" path="$2"
    if [[ -n "$repo_name" ]]; then
        echo "$repo_name"
    elif [[ -n "$path" ]]; then
        basename "$path"
    else
        echo "zzz"
    fi
}

match_sessions() {
    session_entries=()
    orphaned_sessions=()
    local matched_paths=()

    for si in "${!session_names[@]}"; do
        local sname="${session_names[$si]}"
        local sstate="${session_states[$si]}"
        local sactivity="${session_activities[$si]}"
        local spath="${session_paths[$si]}"
        local srepo="${session_repos[$si]}"
        local sbranch="${session_branches[$si]}"
        local snote="${session_notes[$si]}"
        local session_agent matched repo_name branch path label

        session_agent=$(session_agent_from_name "$sname")
        matched=$(find_entry_for_session "$sname" "$spath" "$srepo" "$sbranch" || true)

        if [[ -n "$matched" ]]; then
            IFS='|' read -r repo_name branch path <<< "$matched"
            [[ -n "$srepo" ]] || srepo="$repo_name"
            [[ -n "$sbranch" ]] || sbranch="$branch"
            [[ -n "$spath" ]] || spath="$path"
            [[ -n "$spath" ]] && matched_paths+=("$spath")
            label=$(session_display_label "$srepo" "$sbranch" "$session_agent" "$sname" "$snote")
            session_entries+=("${label}|live|${sname}|${sstate}|${sactivity}|${spath}|${srepo}|${sbranch}|$(session_sort_key "$srepo" "$spath")")
        else
            label=$(session_display_label "$srepo" "$sbranch" "$session_agent" "$sname" "$snote")
            session_entries+=("${label}|live|${sname}|${sstate}|${sactivity}|${spath}|${srepo}|${sbranch}|$(session_sort_key "$srepo" "$spath")")
            orphaned_sessions+=("${sname}|${sstate}|${sactivity}")
        fi
    done

    for ei in "${!entries[@]}"; do
        IFS='|' read -r repo_name branch path kind <<< "${entries[$ei]}"
        [[ "$kind" == "worktree" ]] || continue

        local already_matched=false matched_path
        for matched_path in "${matched_paths[@]:-}"; do
            if [[ "$matched_path" == "$path" ]]; then
                already_matched=true
                break
            fi
        done
        [[ "$already_matched" == true ]] && continue

        label="${repo_name}  ${branch}"
        session_entries+=("${label}|worktree||dormant|0|${path}|${repo_name}|${branch}|$(session_sort_key "$repo_name" "$path")")
    done

    if [[ ${#session_entries[@]} -gt 1 ]]; then
        local sorted_entries=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && sorted_entries+=("$line")
        done < <(printf '%s\n' "${session_entries[@]}" | sort -t '|' -k9,9 -k5,5nr -k2,2)
        session_entries=("${sorted_entries[@]}")
    fi
}

compute_default() {
    default_idx=0
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
    echo "  Projects"
    if [[ ${#project_entries[@]} -eq 0 ]]; then
        echo "  (no repos — press m to clone)"
    else
        for i in "${!project_entries[@]}"; do
            IFS='|' read -r repo_name branch _path kind repo_warning repo_refreshing <<< "${project_entries[$i]}"
            local marker=""
            if [[ -n "$repo_warning" ]]; then
                marker="  blocked"
            elif [[ -n "$repo_refreshing" ]]; then
                marker="  refreshing"
            fi
            echo "  [${idx}] ${repo_name}  ${branch}${marker}"
            ((idx++))
        done
    fi

    echo ""
    echo "  Sessions"
    if [[ ${#session_entries[@]} -eq 0 ]]; then
        echo "  (none)"
    else
        for entry in "${session_entries[@]}"; do
            IFS='|' read -r label kind _sname sstate _sactivity _spath _repo _branch _sort_key <<< "$entry"
            local marker=""
            if [[ "$kind" == "worktree" ]]; then
                marker="  worktree"
            elif [[ "$sstate" == "attached" ]]; then
                marker="  attached"
            elif [[ "$sstate" == "idle" ]]; then
                marker="  active"
            fi
            echo "  [${idx}] ${label}${marker}"
            ((idx++))
        done
    fi

    echo ""
    if [[ ${#project_entries[@]} -gt 0 || ${#session_entries[@]} -gt 0 ]]; then
        echo "  Enter=1  agent=${CODE_AGENT}  t=toggle->${next_agent}  m=manage${footer_actions:+  ${footer_actions}}"
    else
        echo "  Enter=m  agent=${CODE_AGENT}  t=toggle->${next_agent}  m=manage${footer_actions:+  ${footer_actions}}"
    fi
    echo ""
}

prepare_project_launch() {
    :
}

prepare_picker_state() {
    :
}

prepare_manager_launch() {
    :
}

select_entry() {
    local idx="$1"

    if [[ $idx -lt ${#project_entries[@]} ]]; then
        IFS='|' read -r repo_name default_branch main_path kind _repo_warning _repo_refreshing <<< "${project_entries[$idx]}"
        prepare_project_launch "$main_path" "$repo_name" "$default_branch" || return 1
        launch "${LAUNCH_PATH:-$main_path}" "${LAUNCH_BRANCH:-$default_branch}" "${LAUNCH_REPO_NAME:-$repo_name}" || return 1
    else
        local oi=$(( idx - ${#project_entries[@]} ))
        IFS='|' read -r _label kind sname _state _activity path repo_name branch _sort_key <<< "${session_entries[$oi]}"
        if [[ "$kind" == "worktree" ]]; then
            launch "$path" "$branch" "$repo_name" || return 1
        else
            echo "  -> $sname"
            echo ""
            attach_tmux_session "$sname"
        fi
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
        get_sessions
        prepare_picker_state
        discover_entries
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
            if [[ ${#project_entries[@]} -gt 0 || ${#session_entries[@]} -gt 0 ]]; then
                select_entry 0 || true
            else
                prepare_manager_launch || continue
                launch_manager "$MANAGER_TARGET" || true
            fi
            continue
        elif [[ "$choice" =~ ^[0-9]+$ ]]; then
            idx=$(( choice - 1 ))
            total=$(( ${#project_entries[@]} + ${#session_entries[@]} ))
            if [[ $idx -ge 0 && $idx -lt $total ]]; then
                select_entry "$idx" || true
            fi
        fi
    done
}
