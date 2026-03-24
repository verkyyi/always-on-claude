#!/bin/bash
# install-cloudwatch-alarms.sh — Create CloudWatch memory alarms for the instance.
#
# Requires:
#   - CloudWatch agent running and publishing mem_used_percent
#   - IAM permissions: cloudwatch:PutMetricAlarm, sns:CreateTopic, sns:Subscribe
#
# Idempotent — safe to re-run.

set -euo pipefail

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
skip()  { echo "  SKIP: $* (already done)"; }

# Wrap sudo: no-op when already root
if [[ $EUID -eq 0 ]]; then
    sudo() { "$@"; }
fi

info "CloudWatch memory alarms"

# --- Resolve instance metadata ----------------------------------------------

# Try IMDSv2 first, fall back to IMDSv1
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)

get_meta() {
    local path="$1"
    if [[ -n "$TOKEN" ]]; then
        curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
            "http://169.254.169.254/latest/meta-data/$path" 2>/dev/null
    else
        curl -sf "http://169.254.169.254/latest/meta-data/$path" 2>/dev/null
    fi
}

INSTANCE_ID=$(get_meta "instance-id" || true)
REGION=$(get_meta "placement/region" || true)

if [[ -z "$INSTANCE_ID" || -z "$REGION" ]]; then
    echo "  WARN: Could not retrieve instance metadata — skipping CloudWatch alarms."
    echo "  (This is expected on non-EC2 hosts.)"
    exit 0
fi

# --- Check IAM permissions --------------------------------------------------

if ! aws cloudwatch describe-alarms --max-items 1 --region "$REGION" &>/dev/null 2>&1; then
    echo "  WARN: No CloudWatch permissions — skipping alarms."
    echo "  Grant cloudwatch:PutMetricAlarm and sns:CreateTopic to the instance role."
    exit 0
fi

# --- SNS topic --------------------------------------------------------------

TOPIC_NAME="always-on-claude-alerts"
TOPIC_ARN=$(aws sns create-topic --name "$TOPIC_NAME" --region "$REGION" \
    --query 'TopicArn' --output text 2>/dev/null || true)

if [[ -z "$TOPIC_ARN" ]]; then
    echo "  WARN: Could not create SNS topic — skipping alarms."
    exit 0
fi
ok "SNS topic: $TOPIC_ARN"

# --- Memory warning alarm (>80% for 10 min) ---------------------------------

ALARM_WARNING="always-on-claude-memory-warning"
if aws cloudwatch describe-alarms --alarm-names "$ALARM_WARNING" --region "$REGION" \
    --query 'MetricAlarms[0].AlarmName' --output text 2>/dev/null | grep -q "$ALARM_WARNING"; then
    skip "Warning alarm already exists"
else
    aws cloudwatch put-metric-alarm \
        --alarm-name "$ALARM_WARNING" \
        --alarm-description "Memory usage >80% for 10 minutes" \
        --namespace CWAgent \
        --metric-name mem_used_percent \
        --dimensions "Name=InstanceId,Value=$INSTANCE_ID" \
        --statistic Average \
        --period 300 \
        --evaluation-periods 2 \
        --threshold 80 \
        --comparison-operator GreaterThanThreshold \
        --alarm-actions "$TOPIC_ARN" \
        --region "$REGION"
    ok "Warning alarm created (>80% for 10 min)"
fi

# --- Memory critical alarm (>90% for 1 min) ---------------------------------

ALARM_CRITICAL="always-on-claude-memory-critical"
if aws cloudwatch describe-alarms --alarm-names "$ALARM_CRITICAL" --region "$REGION" \
    --query 'MetricAlarms[0].AlarmName' --output text 2>/dev/null | grep -q "$ALARM_CRITICAL"; then
    skip "Critical alarm already exists"
else
    aws cloudwatch put-metric-alarm \
        --alarm-name "$ALARM_CRITICAL" \
        --alarm-description "Memory usage >90% for 1 minute — OOM imminent" \
        --namespace CWAgent \
        --metric-name mem_used_percent \
        --dimensions "Name=InstanceId,Value=$INSTANCE_ID" \
        --statistic Average \
        --period 60 \
        --evaluation-periods 1 \
        --threshold 90 \
        --comparison-operator GreaterThanThreshold \
        --alarm-actions "$TOPIC_ARN" \
        --region "$REGION"
    ok "Critical alarm created (>90% for 1 min)"
fi

# --- Prompt for email subscription ------------------------------------------

echo ""
echo "  To receive alerts, subscribe your email:"
echo "    aws sns subscribe --topic-arn $TOPIC_ARN --protocol email --notification-endpoint YOUR_EMAIL --region $REGION"
echo ""
