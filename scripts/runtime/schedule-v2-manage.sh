#!/bin/bash
# schedule-v2-manage.sh — Generate/install v2 native scheduler definitions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/schedule-v2-lib.sh"

usage() {
    cat <<'EOF'
Usage:
  schedule-v2-manage.sh create-job --job-file <json>
  schedule-v2-manage.sh install-job <job-id>
  schedule-v2-manage.sh uninstall-job <job-id>
  schedule-v2-manage.sh install-recovery
  schedule-v2-manage.sh uninstall-recovery
  schedule-v2-manage.sh reinstall-all
  schedule-v2-manage.sh migrate-current-mac
  schedule-v2-manage.sh list
EOF
}

mac_label_for_job() {
    printf 'com.always-on-claude.schedule.%s\n' "$1"
}

linux_unit_for_job() {
    printf 'always-on-claude-schedule-%s\n' "$1"
}

mac_plist_target() {
    printf '%s/Library/LaunchAgents/%s.plist\n' "$HOME" "$(mac_label_for_job "$1")"
}

native_root() {
    if command -v launchctl >/dev/null 2>&1; then
        printf '%s/native/macos\n' "$SCHEDULE_V2_ROOT"
    else
        printf '%s/native/linux\n' "$SCHEDULE_V2_ROOT"
    fi
}

weekday_to_launchd() {
    case "$1" in
        sunday) echo 0 ;;
        monday) echo 1 ;;
        tuesday) echo 2 ;;
        wednesday) echo 3 ;;
        thursday) echo 4 ;;
        friday) echo 5 ;;
        saturday) echo 6 ;;
        *) schedule_v2_die "unsupported weekday: $1" ;;
    esac
}

weekday_to_systemd() {
    case "$1" in
        sunday) echo Sun ;;
        monday) echo Mon ;;
        tuesday) echo Tue ;;
        wednesday) echo Wed ;;
        thursday) echo Thu ;;
        friday) echo Fri ;;
        saturday) echo Sat ;;
        *) schedule_v2_die "unsupported weekday: $1" ;;
    esac
}

generate_launchd_calendar_xml() {
    python3 - "$SCHEDULE_V2_JOB_FILE" <<'PY'
import json
import sys

job_file = sys.argv[1]
with open(job_file, "r", encoding="utf-8") as fh:
    job = json.load(fh)

s = job["schedule"]
kind = s["type"]

parts = []
if kind == "hourly":
    parts.append(("Minute", s["minute"]))
elif kind == "daily":
    parts.extend([("Hour", s["hour"]), ("Minute", s["minute"])])
elif kind == "daily_hours":
    print("<array>")
    for hour in sorted(int(h) for h in s["hours"]):
        print("<dict>")
        print(f"  <key>Hour</key><integer>{hour}</integer>")
        print(f"  <key>Minute</key><integer>{int(s['minute'])}</integer>")
        print("</dict>")
    print("</array>")
    raise SystemExit(0)
elif kind == "weekly":
    weekdays = {
        "sunday": 0, "monday": 1, "tuesday": 2, "wednesday": 3,
        "thursday": 4, "friday": 5, "saturday": 6,
    }
    parts.extend([("Weekday", weekdays[s["weekday"].lower()]), ("Hour", s["hour"]), ("Minute", s["minute"])])
elif kind == "monthly":
    parts.extend([("Day", s["day"]), ("Hour", s["hour"]), ("Minute", s["minute"])])
elif kind == "once":
    local_time = s["local_time"]
    date_part, time_part = local_time.split()
    year, month, day = [int(x) for x in date_part.split("-")]
    hour, minute = [int(x) for x in time_part.split(":")]
    parts.extend([("Year", year), ("Month", month), ("Day", day), ("Hour", hour), ("Minute", minute)])
else:
    raise SystemExit(f"unsupported schedule type: {kind}")

print("<dict>")
for key, value in parts:
    print(f"  <key>{key}</key><integer>{value}</integer>")
print("</dict>")
PY
}

generate_systemd_oncalendar() {
    python3 - "$SCHEDULE_V2_JOB_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    job = json.load(fh)

s = job["schedule"]
kind = s["type"]

if kind == "hourly":
    print(f"*-*-* *:{int(s['minute']):02d}:00")
elif kind == "daily":
    print(f"*-*-* {int(s['hour']):02d}:{int(s['minute']):02d}:00")
elif kind == "daily_hours":
    hours = ",".join(f"{int(h):02d}" for h in sorted(int(h) for h in s["hours"]))
    print(f"*-*-* {hours}:{int(s['minute']):02d}:00")
elif kind == "weekly":
    weekdays = {
        "sunday": "Sun", "monday": "Mon", "tuesday": "Tue", "wednesday": "Wed",
        "thursday": "Thu", "friday": "Fri", "saturday": "Sat",
    }
    print(f"{weekdays[s['weekday'].lower()]} *-*-* {int(s['hour']):02d}:{int(s['minute']):02d}:00")
elif kind == "monthly":
    print(f"*-*-{int(s['day']):02d} {int(s['hour']):02d}:{int(s['minute']):02d}:00")
elif kind == "once":
    date_part, time_part = s["local_time"].split()
    print(f"{date_part} {time_part}:00")
else:
    raise SystemExit(f"unsupported schedule type: {kind}")
PY
}

install_launchd_job() {
    local job_id="$1"
    local label plist_file target_file native_dir

    schedule_v2_load_job "$job_id"
    native_dir="$(native_root)"
    mkdir -p "$native_dir" "$HOME/Library/LaunchAgents"
    label="$(mac_label_for_job "$job_id")"
    plist_file="$native_dir/$label.plist"
    target_file="$(mac_plist_target "$job_id")"

    cat > "$plist_file" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPT_DIR/schedule-v2-run-scheduled.sh</string>
    <string>$job_id</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${DEV_ENV:-$(pwd)}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>AOC_SCHEDULE_DIR</key><string>$SCHEDULE_V2_ROOT</string>
    <key>AOC_DOCKER</key><string>${AOC_DOCKER:-/opt/homebrew/bin/docker}</string>
  </dict>
  <key>StartCalendarInterval</key>
$(generate_launchd_calendar_xml)
  <key>StandardOutPath</key>
  <string>$(schedule_v2_job_log_path "$job_id")</string>
  <key>StandardErrorPath</key>
  <string>$(schedule_v2_job_log_path "$job_id")</string>
</dict>
</plist>
PLIST

    plutil -lint "$plist_file" >/dev/null
    cp "$plist_file" "$target_file"
    launchctl bootout "gui/$(id -u)" "$target_file" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$target_file" >/dev/null 2>&1 || true
    launchctl enable "gui/$(id -u)/$label" >/dev/null 2>&1 || true
    echo "installed $job_id"
}

uninstall_launchd_job() {
    local job_id="$1"
    local label target_file

    label="$(mac_label_for_job "$job_id")"
    target_file="$(mac_plist_target "$job_id")"
    launchctl bootout "gui/$(id -u)" "$target_file" >/dev/null 2>&1 || true
    rm -f "$target_file"
    echo "uninstalled $job_id"
}

install_systemd_job() {
    local job_id="$1"
    local native_dir unit_name oncalendar service_file timer_file

    schedule_v2_load_job "$job_id"
    native_dir="$(native_root)"
    mkdir -p "$native_dir"
    unit_name="$(linux_unit_for_job "$job_id")"
    service_file="$native_dir/$unit_name.service"
    timer_file="$native_dir/$unit_name.timer"
    oncalendar="$(generate_systemd_oncalendar)"

    cat > "$service_file" <<EOF
[Unit]
Description=Always-on-claude v2 job $job_id

[Service]
Type=oneshot
Environment=HOME=$HOME
Environment=AOC_SCHEDULE_DIR=$SCHEDULE_V2_ROOT
Environment=AOC_DOCKER=${AOC_DOCKER:-docker}
WorkingDirectory=${DEV_ENV:-$(pwd)}
ExecStart=/bin/bash $SCRIPT_DIR/schedule-v2-run-scheduled.sh $job_id
EOF

    cat > "$timer_file" <<EOF
[Unit]
Description=Always-on-claude v2 timer $job_id

[Timer]
OnCalendar=$oncalendar
Persistent=true

[Install]
WantedBy=timers.target
EOF
    echo "generated $job_id"
}

install_recovery() {
    local native_dir label plist_file target_file

    native_dir="$(native_root)"
    mkdir -p "$native_dir" "$HOME/Library/LaunchAgents"
    if command -v launchctl >/dev/null 2>&1; then
        label="com.always-on-claude.schedule-recovery"
        plist_file="$native_dir/$label.plist"
        target_file="$HOME/Library/LaunchAgents/$label.plist"
        cat > "$plist_file" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPT_DIR/schedule-v2-recover.sh</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${DEV_ENV:-$(pwd)}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>AOC_SCHEDULE_DIR</key><string>$SCHEDULE_V2_ROOT</string>
    <key>AOC_DOCKER</key><string>${AOC_DOCKER:-/opt/homebrew/bin/docker}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>$SCHEDULE_V2_LOGS_DIR/recovery.log</string>
  <key>StandardErrorPath</key><string>$SCHEDULE_V2_LOGS_DIR/recovery.log</string>
</dict>
</plist>
PLIST
        plutil -lint "$plist_file" >/dev/null
        cp "$plist_file" "$target_file"
        launchctl bootout "gui/$(id -u)" "$target_file" >/dev/null 2>&1 || true
        launchctl bootstrap "gui/$(id -u)" "$target_file" >/dev/null 2>&1 || true
        launchctl enable "gui/$(id -u)/$label" >/dev/null 2>&1 || true
    else
        mkdir -p "$native_dir"
        cat > "$native_dir/always-on-claude-schedule-recovery.service" <<EOF
[Unit]
Description=Always-on-claude v2 recovery

[Service]
Type=oneshot
Environment=HOME=$HOME
Environment=AOC_SCHEDULE_DIR=$SCHEDULE_V2_ROOT
Environment=AOC_DOCKER=${AOC_DOCKER:-docker}
WorkingDirectory=${DEV_ENV:-$(pwd)}
ExecStart=/bin/bash $SCRIPT_DIR/schedule-v2-recover.sh
EOF
        cat > "$native_dir/always-on-claude-schedule-recovery.timer" <<EOF
[Unit]
Description=Always-on-claude v2 recovery timer

[Timer]
OnBootSec=1min
OnUnitActiveSec=60

[Install]
WantedBy=timers.target
EOF
    fi
    echo "installed recovery"
}

uninstall_recovery() {
    local label target_file
    if command -v launchctl >/dev/null 2>&1; then
        label="com.always-on-claude.schedule-recovery"
        target_file="$HOME/Library/LaunchAgents/$label.plist"
        launchctl bootout "gui/$(id -u)" "$target_file" >/dev/null 2>&1 || true
        rm -f "$target_file"
    fi
    echo "uninstalled recovery"
}

create_migrated_job_defs_for_current_mac() {
    mkdir -p "$SCHEDULE_V2_JOBS_DIR"
    cat > "$SCHEDULE_V2_JOBS_DIR/daily-brief-am.json" <<'EOF'
{
  "version": 2,
  "id": "daily-brief-am",
  "label": "daily-brief-am",
  "timezone": "America/Los_Angeles",
  "schedule": {"type":"daily","hour":6,"minute":30},
  "grace_window_sec": 43200,
  "cwd": "/home/dev/projects/dashboard",
  "command": "python3 scripts/daily_brief/brief.py am --date \"$AOC_SCHEDULE_SLOT_DATE\"",
  "container_service": "dev",
  "compose_file": "docker-compose.macmini.yml",
  "timeout_sec": 1200,
  "enabled": true
}
EOF
    cat > "$SCHEDULE_V2_JOBS_DIR/daily-brief-pm.json" <<'EOF'
{
  "version": 2,
  "id": "daily-brief-pm",
  "label": "daily-brief-pm",
  "timezone": "America/Los_Angeles",
  "schedule": {"type":"daily","hour":16,"minute":30},
  "grace_window_sec": 43200,
  "cwd": "/home/dev/projects/dashboard",
  "command": "python3 scripts/daily_brief/brief.py pm --date \"$AOC_SCHEDULE_SLOT_DATE\"",
  "container_service": "dev",
  "compose_file": "docker-compose.macmini.yml",
  "timeout_sec": 1200,
  "enabled": true
}
EOF
    cat > "$SCHEDULE_V2_JOBS_DIR/dashboard-nightly.json" <<'EOF'
{
  "version": 2,
  "id": "dashboard-nightly",
  "label": "dashboard-nightly",
  "timezone": "America/Los_Angeles",
  "schedule": {"type":"daily","hour":21,"minute":30},
  "grace_window_sec": 86400,
  "cwd": "/home/dev/projects/dashboard",
  "command": "./dashboard/nightly.sh",
  "container_service": "dev",
  "compose_file": "docker-compose.macmini.yml",
  "timeout_sec": 3600,
  "enabled": true
}
EOF
    cat > "$SCHEDULE_V2_JOBS_DIR/dashboard-hourly.json" <<'EOF'
{
  "version": 2,
  "id": "dashboard-hourly",
  "label": "dashboard-hourly",
  "timezone": "America/Los_Angeles",
  "schedule": {"type":"hourly","minute":0},
  "grace_window_sec": 7200,
  "cwd": "/home/dev/projects/dashboard",
  "command": "./dashboard/hourly_fast.sh",
  "container_service": "dev",
  "compose_file": "docker-compose.macmini.yml",
  "timeout_sec": 1200,
  "enabled": true
}
EOF
    cat > "$SCHEDULE_V2_JOBS_DIR/dashboard-agent.json" <<'EOF'
{
  "version": 2,
  "id": "dashboard-agent",
  "label": "dashboard-agent",
  "timezone": "America/Los_Angeles",
  "schedule": {"type":"daily_hours","hours":[0,3,6,9,12,15,18,21],"minute":10},
  "grace_window_sec": 21600,
  "cwd": "/home/dev/projects/dashboard",
  "command": "./dashboard/agent_refresh.sh",
  "container_service": "dev",
  "compose_file": "docker-compose.macmini.yml",
  "timeout_sec": 1800,
  "enabled": true
}
EOF
}

reinstall_all() {
    local job_id
    for job_id in $(schedule_v2_list_job_ids); do
        if command -v launchctl >/dev/null 2>&1; then
            install_launchd_job "$job_id"
        else
            install_systemd_job "$job_id"
        fi
    done
    install_recovery
}

seed_v1_success_to_v2_slot() {
    local job_id="$1"
    local label="$2"
    local slot latest_file run_status

    schedule_v2_load_job "$job_id"
    latest_file="$(jq -r --arg label "$label" 'select(.label == $label) | .updated_at + "\t" + input_filename' "$SCHEDULE_V2_STATUS_DIR"/*.json 2>/dev/null | sort | tail -1 | cut -f2-)"
    [[ -n "$latest_file" ]] || return 0

    run_status="$(jq -r '.last_run_status // .status // empty' "$latest_file" 2>/dev/null || true)"
    [[ "$run_status" == "succeeded" ]] || return 0

    slot="$(schedule_v2_compute_slot "$SCHEDULE_V2_JOB_FILE")"
    schedule_v2_write_slot_ledger "$job_id" "$slot" "scheduled" "succeeded" 0 "" "" "$(schedule_v2_now_local)"
    schedule_v2_write_status "$job_id" "$slot" "scheduled" "scheduled" "succeeded" 0
    echo "seeded $job_id from $label"
}

seed_current_mac() {
    seed_v1_success_to_v2_slot "daily-brief-am" "daily-brief-am-due"
    seed_v1_success_to_v2_slot "dashboard-nightly" "dashboard-nightly-due"
}

main() {
    local cmd="${1:-}"
    case "$cmd" in
        install-job)
            shift
            [[ $# -eq 1 ]] || schedule_v2_die "install-job requires <job-id>"
            schedule_v2_ensure_dirs
            if command -v launchctl >/dev/null 2>&1; then
                install_launchd_job "$1"
            else
                install_systemd_job "$1"
            fi
            ;;
        uninstall-job)
            shift
            [[ $# -eq 1 ]] || schedule_v2_die "uninstall-job requires <job-id>"
            if command -v launchctl >/dev/null 2>&1; then
                uninstall_launchd_job "$1"
            else
                echo "linux uninstall not yet implemented"
            fi
            ;;
        install-recovery)
            install_recovery
            ;;
        uninstall-recovery)
            uninstall_recovery
            ;;
        reinstall-all)
            reinstall_all
            ;;
        migrate-current-mac)
            schedule_v2_ensure_dirs
            create_migrated_job_defs_for_current_mac
            reinstall_all
            seed_current_mac
            ;;
        seed-current-mac)
            seed_current_mac
            ;;
        list)
            schedule_v2_list_job_ids
            ;;
        -h|--help|help|"")
            usage
            ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
}

main "$@"
