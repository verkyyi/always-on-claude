# Workspace Backup

You are managing EBS snapshots for an always-on Claude Code workspace. This provides backup and restore capabilities via the scoped IAM credentials available in the workspace.

## Context

- Workspace info: !`cat .env.workspace 2>/dev/null || echo "NOT FOUND"`
- AWS identity: !`aws sts get-caller-identity 2>&1 | head -5`
- AWS region: !`aws configure get region 2>/dev/null || echo "not set"`

---

## Before you start

If `.env.workspace` is missing or `WORKSPACE_TYPE` is `local-mac`, tell the user:
"This command is only available on EC2 workspaces. EBS snapshots require an EC2 instance with an attached volume."
Then stop.

If the AWS CLI context above shows an error, stop and help the user fix their credentials.

Source `.env.workspace` to get `INSTANCE_ID`, `REGION`, and other variables.

If `$ARGUMENTS` is provided, parse it for a subcommand:
- `backup` or empty → create a snapshot (default)
- `list` → list existing snapshots
- `restore` → describe how to restore
- `prune` or `prune N` → delete old snapshots (keep last N, default 5)

---

## Subcommand: Create snapshot (default)

### Step 1 — Get instance and volume info

Get the instance ID from EC2 metadata (works inside the container with host networking):
```bash
INSTANCE_ID=$(curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null) || true
```

If metadata is unavailable, fall back to `.env.workspace`:
```bash
source .env.workspace 2>/dev/null || true
echo "INSTANCE_ID=${INSTANCE_ID:-not found}"
```

Get the root volume ID:
```bash
VOLUME_ID=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName==`/dev/sda1`].Ebs.VolumeId' \
    --output text)
echo "VOLUME_ID=$VOLUME_ID"
```

### Step 2 — Create the snapshot

```bash
TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
SNAPSHOT_ID=$(aws ec2 create-snapshot \
    --region "$REGION" \
    --volume-id "$VOLUME_ID" \
    --description "always-on-claude backup $TIMESTAMP" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=claude-backup-$TIMESTAMP},{Key=Project,Value=always-on-claude},{Key=InstanceId,Value=$INSTANCE_ID},{Key=CreatedBy,Value=backup-command}]" \
    --query 'SnapshotId' \
    --output text)
echo "Snapshot: $SNAPSHOT_ID"
```

### Step 3 — Confirm

Show the user:
```
Snapshot created!

  Snapshot ID: $SNAPSHOT_ID
  Volume:      $VOLUME_ID
  Timestamp:   $TIMESTAMP

  The snapshot is being created in the background.
  Check progress: /backup list
```

---

## Subcommand: List snapshots

List all snapshots tagged with `Project=always-on-claude`:

```bash
aws ec2 describe-snapshots \
    --region "$REGION" \
    --filters "Name=tag:Project,Values=always-on-claude" \
    --query 'Snapshots | sort_by(@, &StartTime) | reverse(@).[].[SnapshotId,StartTime,State,VolumeSize,Description]' \
    --output table
```

Present the results in a readable format showing:
- Snapshot ID
- Created timestamp
- State (pending/completed/error)
- Size
- Description

If no snapshots are found, tell the user:
"No backups found. Run `/backup` to create one."

---

## Subcommand: Restore

Restoring from a snapshot requires creating a new volume and either swapping the root volume or launching a new instance. Walk the user through the options:

### Option A — Launch a new instance from snapshot

1. List available snapshots (use the list subcommand)
2. Ask the user which snapshot to restore from
3. Create an AMI from the snapshot:
   ```bash
   AMI_ID=$(aws ec2 register-image \
       --region "$REGION" \
       --name "claude-restore-$SNAPSHOT_ID" \
       --root-device-name /dev/sda1 \
       --block-device-mappings "DeviceName=/dev/sda1,Ebs={SnapshotId=$SNAPSHOT_ID,VolumeType=gp3,DeleteOnTermination=true}" \
       --architecture arm64 \
       --virtualization-type hvm \
       --ena-support \
       --query 'ImageId' \
       --output text)
   ```
4. Tell the user to run `/provision` and use this AMI, or launch manually:
   ```bash
   aws ec2 run-instances \
       --region "$REGION" \
       --image-id "$AMI_ID" \
       --instance-type t4g.small \
       ...
   ```

### Option B — Attach snapshot as secondary volume (data recovery)

1. Create a volume from the snapshot:
   ```bash
   VOLUME_ID=$(aws ec2 create-volume \
       --region "$REGION" \
       --availability-zone "$AZ" \
       --snapshot-id "$SNAPSHOT_ID" \
       --volume-type gp3 \
       --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=claude-restore},{Key=Project,Value=always-on-claude}]" \
       --query 'VolumeId' \
       --output text)
   ```
2. Attach it to the current instance and mount it to copy files

Explain both options and let the user choose. Recommend Option A for full restore and Option B for selective file recovery.

---

## Subcommand: Prune

Delete old snapshots, keeping the most recent N (default 5).

### Step 1 — List all snapshots sorted by date

```bash
aws ec2 describe-snapshots \
    --region "$REGION" \
    --filters "Name=tag:Project,Values=always-on-claude" \
    --query 'Snapshots | sort_by(@, &StartTime) | reverse(@).[].[SnapshotId,StartTime,Description]' \
    --output text
```

### Step 2 — Identify snapshots to delete

Keep the most recent N snapshots (default 5, or the number specified in `$ARGUMENTS`). Show the user which snapshots will be kept and which will be deleted.

```
Keeping (most recent 5):
  snap-abc123  2026-03-20T10:00:00Z  always-on-claude backup ...
  snap-def456  2026-03-19T10:00:00Z  always-on-claude backup ...
  ...

Deleting:
  snap-ghi789  2026-03-10T10:00:00Z  always-on-claude backup ...
  snap-jkl012  2026-03-05T10:00:00Z  always-on-claude backup ...
```

### Step 3 — Confirm and delete

Ask the user to confirm before deleting. Then delete each old snapshot:

```bash
aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$SNAPSHOT_ID"
```

Report how many were deleted.

---

## Error handling

- **No instance ID**: check EC2 metadata endpoint and `.env.workspace`
- **No volume found**: instance may use a different device name — try listing all block devices
- **Permission denied on snapshot**: IAM user may need `ec2:CreateSnapshot`, `ec2:DeleteSnapshot`, `ec2:DescribeSnapshots` permissions
- **Snapshot stuck in pending**: this is normal — EBS snapshots are asynchronous and can take minutes for large volumes

Do NOT delete snapshots without explicit user confirmation.
