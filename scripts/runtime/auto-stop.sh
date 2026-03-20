#!/bin/bash
# auto-stop.sh — Schedule automatic stop/start for the EC2 instance.
#
# Usage:
#   auto-stop.sh --stop HH:MM --start HH:MM   Set stop and start times (UTC)
#   auto-stop.sh --stop HH:MM                  Set stop time only (manual start)
#   auto-stop.sh --status                      Show current schedule
#   auto-stop.sh --remove                      Remove all schedules
#
# Stop uses a cron job on the host that calls `aws ec2 stop-instances`.
# Start uses an EventBridge Scheduler rule that calls `ec2:StartInstances`.
#
# Runs on the host (not inside the container).

set -euo pipefail

# --- Helpers ----------------------------------------------------------------

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
die()   { echo "ERROR: $*" >&2; exit 1; }

# --- Metadata ---------------------------------------------------------------

METADATA="http://169.254.169.254/latest/meta-data"
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || true

meta() {
    if [[ -n "$TOKEN" ]]; then
        curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" "$METADATA/$1" 2>/dev/null
    else
        curl -sf "$METADATA/$1" 2>/dev/null
    fi
}

INSTANCE_ID=$(meta "instance-id" || echo "")
AZ=$(meta "placement/availability-zone" || echo "")
REGION="${AZ%?}"

if [[ -z "$INSTANCE_ID" ]]; then
    die "Could not reach EC2 metadata. Are you running on an EC2 instance?"
fi

if [[ -z "$REGION" ]]; then
    die "Could not determine AWS region from instance metadata"
fi

CRON_TAG="# auto-stop-claude"
RULE_NAME="auto-start-claude-${INSTANCE_ID}"

# --- Parse arguments --------------------------------------------------------

STOP_TIME=""
START_TIME=""
ACTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stop)
            STOP_TIME="$2"
            shift 2
            ;;
        --start)
            START_TIME="$2"
            shift 2
            ;;
        --status)
            ACTION="status"
            shift
            ;;
        --remove)
            ACTION="remove"
            shift
            ;;
        *)
            die "Unknown option: $1. Usage: auto-stop.sh --stop HH:MM [--start HH:MM] | --status | --remove"
            ;;
    esac
done

if [[ -z "$ACTION" && -z "$STOP_TIME" ]]; then
    ACTION="status"
fi

# --- Validate time format ---------------------------------------------------

validate_time() {
    local time="$1" label="$2"
    if ! [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        die "Invalid $label time: $time (expected HH:MM in 24-hour format, e.g. 08:00 or 23:30)"
    fi
}

# --- Status -----------------------------------------------------------------

show_status() {
    info "Auto-stop Schedule"
    echo ""

    local has_schedule=0

    # Check cron for stop schedule
    local stop_cron
    stop_cron=$(crontab -l 2>/dev/null | grep "$CRON_TAG" || true)
    if [[ -n "$stop_cron" ]]; then
        local stop_min stop_hr
        stop_min=$(echo "$stop_cron" | awk '{print $1}')
        stop_hr=$(echo "$stop_cron" | awk '{print $2}')
        echo "  Stop:   ${stop_hr}:${stop_min} UTC (cron)"
        has_schedule=1
    else
        echo "  Stop:   not scheduled"
    fi

    # Check EventBridge for start schedule
    local start_rule
    start_rule=$(aws events describe-rule \
        --region "$REGION" \
        --name "$RULE_NAME" 2>/dev/null || true)
    if [[ -n "$start_rule" ]]; then
        local schedule_expr
        schedule_expr=$(echo "$start_rule" | grep -o '"ScheduleExpression":"[^"]*"' | cut -d'"' -f4)
        local state
        state=$(echo "$start_rule" | grep -o '"State":"[^"]*"' | cut -d'"' -f4)
        echo "  Start:  $schedule_expr ($state)"
        has_schedule=1
    else
        echo "  Start:  not scheduled"
    fi

    echo ""
    if [[ $has_schedule -eq 0 ]]; then
        echo "  No auto-stop schedule configured."
        echo "  Set one: auto-stop.sh --stop 00:00 --start 08:00"
    fi
    echo ""
}

# --- Remove -----------------------------------------------------------------

do_remove() {
    info "Removing Auto-stop Schedule"
    echo ""

    # Remove cron entry
    local existing
    existing=$(crontab -l 2>/dev/null || true)
    if echo "$existing" | grep -q "$CRON_TAG"; then
        echo "$existing" | grep -v "$CRON_TAG" | crontab -
        ok "Removed stop cron job"
    else
        echo "  No stop cron job found"
    fi

    # Remove EventBridge rule
    if aws events describe-rule --region "$REGION" --name "$RULE_NAME" &>/dev/null; then
        # Remove targets first
        local targets_text
        targets_text=$(aws events list-targets-by-rule \
            --region "$REGION" \
            --rule "$RULE_NAME" \
            --query 'Targets[].Id' \
            --output text 2>/dev/null || true)
        if [[ -n "$targets_text" ]]; then
            local target_arr
            mapfile -t target_arr < <(printf '%s\n' $targets_text)
            aws events remove-targets \
                --region "$REGION" \
                --rule "$RULE_NAME" \
                --ids "${target_arr[@]}" >/dev/null
        fi
        aws events delete-rule \
            --region "$REGION" \
            --name "$RULE_NAME" >/dev/null
        ok "Removed EventBridge start rule"
    else
        echo "  No EventBridge start rule found"
    fi

    echo ""
}

# --- Set schedule -----------------------------------------------------------

do_schedule() {
    validate_time "$STOP_TIME" "stop"

    local stop_hr stop_min
    IFS=':' read -r stop_hr stop_min <<< "$STOP_TIME"

    info "Setting Auto-stop Schedule"
    echo ""

    # --- Set up cron stop job ---
    # Remove existing auto-stop entry if present
    local existing
    existing=$(crontab -l 2>/dev/null || true)
    local filtered
    filtered=$(echo "$existing" | grep -v "$CRON_TAG" || true)

    # AWS CLI stop command
    local stop_cmd="aws ec2 stop-instances --region $REGION --instance-ids $INSTANCE_ID >/dev/null 2>&1 $CRON_TAG"
    local new_cron
    if [[ -n "$filtered" ]]; then
        new_cron=$(printf '%s\n%s %s * * * %s' "$filtered" "$stop_min" "$stop_hr" "$stop_cmd")
    else
        new_cron=$(printf '%s %s * * * %s' "$stop_min" "$stop_hr" "$stop_cmd")
    fi
    echo "$new_cron" | crontab -
    ok "Stop scheduled at $stop_hr:$stop_min UTC (cron)"

    # --- Set up EventBridge start rule (if start time given) ---
    if [[ -n "$START_TIME" ]]; then
        validate_time "$START_TIME" "start"

        local start_hr start_min
        IFS=':' read -r start_hr start_min <<< "$START_TIME"

        # Create or update the EventBridge rule
        aws events put-rule \
            --region "$REGION" \
            --name "$RULE_NAME" \
            --schedule-expression "cron($start_min $start_hr * * ? *)" \
            --state ENABLED \
            --description "Auto-start always-on-claude instance $INSTANCE_ID" \
            >/dev/null 2>&1 || {
                echo "  WARN: Could not create EventBridge rule."
                echo "  The instance will stop on schedule but must be started manually."
                echo "  Ensure the instance has events:PutRule and events:PutTargets IAM permissions."
                echo ""
                return
            }

        # Get the account ID for the ARN
        local account_id
        account_id=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null || echo "")

        if [[ -z "$account_id" ]]; then
            echo "  WARN: Could not determine AWS account ID for EventBridge target."
            echo "  Stop schedule is set, but auto-start may not work."
            echo ""
            return
        fi

        # Check if a role for EventBridge exists; create if not
        local role_name="auto-start-claude-role"
        local role_arn="arn:aws:iam::${account_id}:role/${role_name}"

        if ! aws iam get-role --role-name "$role_name" &>/dev/null; then
            # Create the IAM role with EventBridge trust
            local trust_policy
            trust_policy=$(cat <<'TRUST'
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "events.amazonaws.com"},
        "Action": "sts:AssumeRole"
    }]
}
TRUST
)
            aws iam create-role \
                --role-name "$role_name" \
                --assume-role-policy-document "$trust_policy" \
                >/dev/null 2>&1 || {
                    echo "  WARN: Could not create IAM role for EventBridge."
                    echo "  Stop schedule is set, but auto-start requires manual IAM setup."
                    echo ""
                    return
                }

            # Attach inline policy for EC2 start
            local ec2_policy
            ec2_policy=$(cat <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Action": "ec2:StartInstances",
        "Resource": "arn:aws:ec2:${REGION}:${account_id}:instance/${INSTANCE_ID}"
    }]
}
POLICY
)
            aws iam put-role-policy \
                --role-name "$role_name" \
                --policy-name "auto-start-ec2" \
                --policy-document "$ec2_policy" \
                >/dev/null 2>&1

            ok "Created IAM role: $role_name"

            # Wait briefly for IAM propagation
            sleep 5
        fi

        role_arn=$(aws iam get-role --role-name "$role_name" --query 'Role.Arn' --output text 2>/dev/null)

        # Add the EC2 start target
        aws events put-targets \
            --region "$REGION" \
            --rule "$RULE_NAME" \
            --targets "Id=start-instance,Arn=arn:aws:ssm:${REGION}::automation-definition/AWS-StartEC2Instance,RoleArn=${role_arn},Input={\"InstanceId\":[\"${INSTANCE_ID}\"]}" \
            >/dev/null 2>&1 || {
                # Fallback: try using a Lambda-less approach via built-in EC2 target
                echo "  WARN: Could not set EventBridge target for auto-start."
                echo "  Stop schedule is set. Start the instance manually or via AWS console."
                echo ""
                return
            }

        ok "Start scheduled at $start_hr:$start_min UTC (EventBridge)"
    fi

    echo ""

    # Show savings estimate
    if [[ -n "$START_TIME" ]]; then
        local start_total_min=$((10#$start_hr * 60 + 10#$start_min))
        local stop_total_min=$((10#$stop_hr * 60 + 10#$stop_min))
        local active_min

        if [[ $start_total_min -lt $stop_total_min ]]; then
            active_min=$((stop_total_min - start_total_min))
        else
            active_min=$((1440 - start_total_min + stop_total_min))
        fi

        local active_hrs=$((active_min / 60))
        local savings_pct=$(( (1440 - active_min) * 100 / 1440 ))

        echo "  Schedule: run ${active_hrs}h/day, stopped $((24 - active_hrs))h/day"
        echo "  Estimated savings: ~${savings_pct}% of compute costs"
        echo ""
    fi
}

# --- Main -------------------------------------------------------------------

case "$ACTION" in
    status)
        show_status
        ;;
    remove)
        do_remove
        ;;
    "")
        do_schedule
        ;;
esac
