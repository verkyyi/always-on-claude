#!/bin/bash
# cost.sh — Show estimated infrastructure costs for the current EC2 instance.
#
# Fetches instance type and launch time from EC2 metadata, looks up pricing
# from a hardcoded table of common on-demand prices (us-east-1), and displays
# a concise, mobile-friendly cost summary.
#
# Runs on the host (not inside the container).

set -euo pipefail

# --- Helpers ----------------------------------------------------------------

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  $*"; }
die()   { echo "ERROR: $*" >&2; exit 1; }

# --- EC2 metadata -----------------------------------------------------------

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

INSTANCE_TYPE=$(meta "instance-type" || echo "unknown")
INSTANCE_ID=$(meta "instance-id" || echo "unknown")
AZ=$(meta "placement/availability-zone" || echo "unknown")
REGION="${AZ%?}"  # strip trailing letter

if [[ "$INSTANCE_TYPE" == "unknown" ]]; then
    die "Could not reach EC2 metadata. Are you running on an EC2 instance?"
fi

# --- Pricing table (us-east-1 on-demand, USD/hr) ---------------------------
# Source: https://aws.amazon.com/ec2/pricing/on-demand/
# Last updated: 2025-01

declare -A PRICES=(
    # T3 (Intel, x86_64)
    ["t3.micro"]="0.0104"
    ["t3.small"]="0.0208"
    ["t3.medium"]="0.0416"
    ["t3.large"]="0.0832"
    ["t3.xlarge"]="0.1664"

    # T3a (AMD, x86_64)
    ["t3a.micro"]="0.0094"
    ["t3a.small"]="0.0188"
    ["t3a.medium"]="0.0376"
    ["t3a.large"]="0.0752"

    # T4g (Graviton, arm64)
    ["t4g.micro"]="0.0084"
    ["t4g.small"]="0.0168"
    ["t4g.medium"]="0.0336"
    ["t4g.large"]="0.0672"
    ["t4g.xlarge"]="0.1344"

    # M6i (Intel, x86_64)
    ["m6i.large"]="0.0960"
    ["m6i.xlarge"]="0.1920"

    # M7g (Graviton, arm64)
    ["m7g.medium"]="0.0408"
    ["m7g.large"]="0.0816"
    ["m7g.xlarge"]="0.1632"

    # C7g (Graviton, arm64)
    ["c7g.medium"]="0.0361"
    ["c7g.large"]="0.0723"

    # R7g (Graviton, arm64)
    ["r7g.medium"]="0.0534"
    ["r7g.large"]="0.1067"
)

HOURLY="${PRICES[$INSTANCE_TYPE]:-}"

if [[ -z "$HOURLY" ]]; then
    HOURLY="unknown"
fi

# --- Instance uptime --------------------------------------------------------

LAUNCH_TIME=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].LaunchTime' \
    --output text 2>/dev/null || echo "unknown")

if [[ "$LAUNCH_TIME" != "unknown" ]]; then
    LAUNCH_EPOCH=$(date -d "$LAUNCH_TIME" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${LAUNCH_TIME%%+*}" +%s 2>/dev/null || echo "0")
    NOW_EPOCH=$(date +%s)
    UPTIME_SECS=$((NOW_EPOCH - LAUNCH_EPOCH))
    UPTIME_HOURS=$((UPTIME_SECS / 3600))
    UPTIME_DAYS=$((UPTIME_HOURS / 24))
    UPTIME_REM_HOURS=$((UPTIME_HOURS % 24))

    if [[ $UPTIME_DAYS -gt 0 ]]; then
        UPTIME_STR="${UPTIME_DAYS}d ${UPTIME_REM_HOURS}h"
    else
        UPTIME_STR="${UPTIME_HOURS}h"
    fi
else
    UPTIME_STR="unknown"
    UPTIME_HOURS=0
fi

# --- EBS storage cost -------------------------------------------------------

EBS_SIZE=$(aws ec2 describe-volumes \
    --region "$REGION" \
    --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" \
    --query 'Volumes[].Size' \
    --output text 2>/dev/null || echo "0")

# Sum all volumes if multiple
TOTAL_EBS=0
for size in $EBS_SIZE; do
    TOTAL_EBS=$((TOTAL_EBS + size))
done

# gp3 pricing: $0.08/GB-month
EBS_MONTHLY=$(awk "BEGIN {printf \"%.2f\", $TOTAL_EBS * 0.08}")

# --- Public IPv4 cost -------------------------------------------------------

# AWS charges $0.005/hr ($3.65/mo) for public IPv4 addresses
IPV4_MONTHLY="3.65"
IPV4_HOURLY="0.005"

# --- Data transfer estimate -------------------------------------------------

# Rough estimate: minimal for SSH/Claude Code usage
DATA_ESTIMATE="~1-5 GB/mo (SSH + git + Claude)"
DATA_COST="\$0.00-0.45"

# --- Compute costs ----------------------------------------------------------

if [[ "$HOURLY" != "unknown" ]]; then
    DAILY=$(awk "BEGIN {printf \"%.2f\", $HOURLY * 24}")
    MONTHLY=$(awk "BEGIN {printf \"%.2f\", $HOURLY * 730}")
    COST_SO_FAR=$(awk "BEGIN {printf \"%.2f\", $HOURLY * $UPTIME_HOURS}")
    TOTAL_MONTHLY=$(awk "BEGIN {printf \"%.2f\", ($HOURLY + $IPV4_HOURLY) * 730 + $TOTAL_EBS * 0.08}")
else
    DAILY="unknown"
    MONTHLY="unknown"
    COST_SO_FAR="unknown"
    TOTAL_MONTHLY="unknown"
fi

# --- Auto-stop schedule check -----------------------------------------------

AUTOSTOP_STATUS=""
if crontab -l 2>/dev/null | grep -q "auto-stop-claude"; then
    STOP_CRON=$(crontab -l 2>/dev/null | grep "auto-stop-claude" | head -1)
    STOP_MIN=$(echo "$STOP_CRON" | awk '{print $1}')
    STOP_HR=$(echo "$STOP_CRON" | awk '{print $2}')
    AUTOSTOP_STATUS="  Auto-stop:  ${STOP_HR}:${STOP_MIN} UTC (active)"
fi

# --- Display ----------------------------------------------------------------

info "Cost Summary"
echo ""
echo "  Instance:     $INSTANCE_TYPE ($INSTANCE_ID)"
echo "  Region:       $REGION ($AZ)"
echo "  Uptime:       $UPTIME_STR"
if [[ -n "$AUTOSTOP_STATUS" ]]; then
    echo "$AUTOSTOP_STATUS"
fi
echo ""
echo "  --- Compute ---"
if [[ "$HOURLY" != "unknown" ]]; then
    echo "  Hourly:       \$$HOURLY/hr"
    echo "  Daily:        \$$DAILY/day"
    echo "  Monthly:      \$$MONTHLY/mo (730 hrs)"
    if [[ "$COST_SO_FAR" != "unknown" ]]; then
        echo "  This session: \$$COST_SO_FAR (${UPTIME_STR})"
    fi
else
    echo "  Hourly:       unknown (instance type $INSTANCE_TYPE not in pricing table)"
    echo "  Check: https://aws.amazon.com/ec2/pricing/on-demand/"
fi
echo ""
echo "  --- Storage ---"
echo "  EBS:          ${TOTAL_EBS} GB gp3 = \$$EBS_MONTHLY/mo"
echo ""
echo "  --- Network ---"
echo "  Public IPv4:  \$$IPV4_MONTHLY/mo"
echo "  Data transfer: $DATA_ESTIMATE"
echo "  Data cost:    $DATA_COST/mo"
echo ""
echo "  --- Total Estimate ---"
if [[ "$TOTAL_MONTHLY" != "unknown" ]]; then
    echo "  Monthly:      ~\$$TOTAL_MONTHLY/mo (always-on)"
    STOPPED_MONTHLY=$(awk "BEGIN {printf \"%.2f\", $TOTAL_EBS * 0.08}")
    echo "  If stopped:   ~\$$STOPPED_MONTHLY/mo (storage only)"
    if [[ "$HOURLY" != "unknown" ]]; then
        HALF_MONTHLY=$(awk "BEGIN {printf \"%.2f\", ($HOURLY + $IPV4_HOURLY) * 365 + $TOTAL_EBS * 0.08}")
        echo "  With auto-stop (12h/day): ~\$$HALF_MONTHLY/mo"
    fi
else
    echo "  Could not calculate total (unknown instance type pricing)"
fi
echo ""
