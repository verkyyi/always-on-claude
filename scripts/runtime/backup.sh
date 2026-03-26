#!/bin/bash
# backup.sh — Create EBS snapshots and prune old ones.
#
# Usage:
#   bash backup.sh              — create a snapshot and prune (keep last 5)
#   bash backup.sh --no-prune   — create a snapshot without pruning
#   bash backup.sh --prune-only — prune only, no new snapshot
#   bash backup.sh --keep N     — keep last N snapshots (default 5)
#
# Designed for cron-based automated daily backups on EC2 instances.
# Uses EC2 instance metadata to discover instance and volume IDs.

set -euo pipefail

# --- Config -----------------------------------------------------------------

KEEP=${KEEP:-5}
TAG="always-on-claude"
NO_PRUNE=false
PRUNE_ONLY=false

# --- Helpers ----------------------------------------------------------------

info()  { echo ""; echo "=== $* ==="; }
ok()    { echo "  OK: $*"; }
skip()  { echo "  SKIP: $* (already done)"; }
die()   { echo "ERROR: $*" >&2; exit 1; }

# --- Parse args -------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-prune)   NO_PRUNE=true; shift ;;
        --prune-only) PRUNE_ONLY=true; shift ;;
        --keep)       KEEP="${2:?--keep requires a number}"; shift 2 ;;
        *)            die "Unknown argument: $1" ;;
    esac
done

[[ "$KEEP" =~ ^[0-9]+$ ]] || die "--keep must be a positive integer"
[[ "$KEEP" -ge 1 ]] || die "--keep must be at least 1"

# --- Preflight --------------------------------------------------------------

info "Preflight checks"

command -v aws &>/dev/null || die "AWS CLI not found"
command -v curl &>/dev/null || die "curl not found"
aws sts get-caller-identity &>/dev/null || die "AWS credentials not configured. Run: aws configure"

# --- Discover instance and volume -------------------------------------------

info "Discovering instance"

# Try EC2 instance metadata (IMDSv2)
TOKEN=$(curl -s --connect-timeout 2 -X PUT \
    "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || true

if [[ -n "${TOKEN:-}" ]]; then
    INSTANCE_ID=$(curl -s --connect-timeout 2 \
        -H "X-aws-ec2-metadata-token: $TOKEN" \
        "http://169.254.169.254/latest/meta-data/instance-id" 2>/dev/null) || true
fi

# Fall back to .env.workspace
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${INSTANCE_ID:-}" ]]; then
    if [[ -f "$SCRIPT_DIR/../../.env.workspace" ]]; then
        # shellcheck source=/dev/null
        source "$SCRIPT_DIR/../../.env.workspace"
    elif [[ -f ".env.workspace" ]]; then
        # shellcheck source=/dev/null
        source ".env.workspace"
    fi
fi

[[ -n "${INSTANCE_ID:-}" ]] || die "Could not determine instance ID (metadata unavailable and no .env.workspace)"

REGION="${REGION:-${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}}"

ok "Instance: $INSTANCE_ID (region: $REGION)"

# Get root volume ID
VOLUME_ID=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName==`/dev/sda1`].Ebs.VolumeId' \
    --output text)

[[ -n "$VOLUME_ID" && "$VOLUME_ID" != "None" ]] || die "Could not find root volume for instance $INSTANCE_ID"

ok "Volume: $VOLUME_ID"

# --- Create snapshot --------------------------------------------------------

if [[ "$PRUNE_ONLY" == "false" ]]; then
    info "Creating snapshot"

    TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)

    SNAPSHOT_ID=$(aws ec2 create-snapshot \
        --region "$REGION" \
        --volume-id "$VOLUME_ID" \
        --description "always-on-claude backup $TIMESTAMP" \
        --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=claude-backup-$TIMESTAMP},{Key=Project,Value=$TAG},{Key=InstanceId,Value=$INSTANCE_ID},{Key=CreatedBy,Value=backup-script}]" \
        --query 'SnapshotId' \
        --output text)

    ok "Snapshot created: $SNAPSHOT_ID"
    echo "  Description: always-on-claude backup $TIMESTAMP"
fi

# --- Prune old snapshots ----------------------------------------------------

if [[ "$NO_PRUNE" == "false" ]]; then
    info "Pruning old snapshots (keeping last $KEEP)"

    # Get all project snapshots sorted newest first
    mapfile -t ALL_SNAPSHOTS < <(aws ec2 describe-snapshots \
        --region "$REGION" \
        --owner-ids self \
        --filters "Name=tag:Project,Values=$TAG" \
        --query 'Snapshots | sort_by(@, &StartTime) | reverse(@).[].SnapshotId' \
        --output text | tr '\t' '\n' | grep -v '^$')

    TOTAL=${#ALL_SNAPSHOTS[@]}

    if [[ $TOTAL -le $KEEP ]]; then
        skip "Only $TOTAL snapshot(s) exist, nothing to prune"
    else
        DELETE_COUNT=$((TOTAL - KEEP))
        echo "  Total snapshots: $TOTAL"
        echo "  Keeping: $KEEP"
        echo "  Deleting: $DELETE_COUNT"

        DELETED=0
        for (( i=KEEP; i<TOTAL; i++ )); do
            snap="${ALL_SNAPSHOTS[$i]}"
            if aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$snap" 2>/dev/null; then
                ok "Deleted $snap"
                DELETED=$((DELETED + 1))
            else
                echo "  WARN: Could not delete $snap"
            fi
        done

        ok "Pruned $DELETED old snapshot(s)"
    fi
fi

# --- Done -------------------------------------------------------------------

echo ""
echo "============================================"
echo "  Backup complete."
echo "============================================"
echo ""
