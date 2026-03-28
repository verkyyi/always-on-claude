You are tearing down an always-on Claude Code workspace on AWS. Confirm with the user before deleting anything.

The user may specify an instance name (e.g., `/destroy claude-dev-2`). If they do, only destroy that specific instance. Check `$ARGUMENTS` for the instance name.

## Context

- Arguments: $ARGUMENTS
- AWS CLI configured: !`aws sts get-caller-identity 2>&1 | head -5`
- AWS region: !`aws configure get region 2>/dev/null || echo "not set"`
- Tagged instances: !`aws ec2 describe-instances --filters "Name=tag:Project,Values=always-on-claude" "Name=instance-state-name,Values=running,stopped,pending" --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress,Tags[?Key==\x60Name\x60].Value|[0],InstanceType]' --output text 2>/dev/null || echo "error — check AWS CLI"`
- Tagged security groups: !`aws ec2 describe-security-groups --filters "Name=tag:Project,Values=always-on-claude" --query 'SecurityGroups[].[GroupId,GroupName]' --output text 2>/dev/null || echo "none"`
- SSH key pairs: !`aws ec2 describe-key-pairs --query 'KeyPairs[].KeyName' --output text 2>/dev/null || echo "error"`
- Local .pem files: !`ls ~/.ssh/*.pem ~/*.pem 2>/dev/null || echo "none"`

---

## Before you start

If the AWS CLI context above shows an error, stop and help the user configure it first.

---

## Step 1 — Determine scope (single instance vs all)

**If the user provided an instance name** (in $ARGUMENTS): filter by that Name tag. Only that instance will be destroyed. Security groups and key pairs are shared resources — do NOT delete them.

**If no name was provided AND multiple instances exist**: list them all with their Name tags, IPs, and instance types. Ask the user which one(s) to delete, or whether to delete all. Example:

```
I found multiple instances:

  1. i-aaa (1.2.3.4, claude-dev, t3.medium)
  2. i-bbb (5.6.7.8, claude-dev-2, t3.medium)

Which instance(s) should I destroy?
  - Enter a number (e.g., "1")
  - Enter a name (e.g., "claude-dev-2")
  - Enter "all" to destroy everything
```

If the user picks a specific instance by name or number, treat it like the named-instance path (skip security groups and key pairs).

**If no name was provided AND only one instance exists**: proceed with full teardown (instance + security groups + key pair).

---

## Step 2 — Show what will be deleted

For a **named instance** (single-instance destroy):
```
I found this instance:

  Instance:        i-xxx (1.2.3.4, claude-dev-2, t3.medium)
  Security groups: skipped (shared)
  Key pair:        skipped (shared)

Delete this instance? [y/N]
```

For **all resources** (full teardown):
```
I found these resources:

  Instances:       i-xxx (1.2.3.4, claude-dev, t3.medium)
  Security groups: sg-xxx (claude-dev-sg)
  Key pair:        claude-dev-key (in AWS + local file)

Delete all of these? [y/N]
```

If nothing is found, say so and exit.

---

## Step 3 — Terminate instances

```bash
aws ec2 terminate-instances --region "$REGION" --instance-ids $INSTANCE_IDS
aws ec2 wait instance-terminated --region "$REGION" --instance-ids $INSTANCE_IDS
```

---

## Step 4 — Delete security groups (full teardown only)

Skip this step if destroying a specific named instance.

```bash
aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID"
```

If deletion fails (still in use from terminating instance), wait a moment and retry.

---

## Step 5 — Delete SSH key pair (full teardown only, ask separately)

Skip this step if destroying a specific named instance.

```
Also delete the SSH key pair "claude-dev-key"? [y/N]
```

If yes:
```bash
aws ec2 delete-key-pair --region "$REGION" --key-name "$KEY_NAME"
rm -f ~/.ssh/$KEY_NAME.pem ~/$KEY_NAME.pem
```

---

## Step 6 — Clean up local files

**Always** clean up the SSH config entry for the destroyed instance name:

Remove the `Host $INSTANCE_NAME` block from `~/.ssh/config` (the Host line and all indented lines below it).

Remove the per-instance workspace file:

```bash
rm -f .env.workspace.$INSTANCE_NAME
```

For full teardown (no name filter), remove all workspace files: `rm -f .env.workspace.*`

---

## Step 7 — Summary

For a **named instance**:
```
Teardown complete.

  Deleted:
    - Instance: i-xxx (claude-dev-2)
    - SSH config entry: claude-dev-2
    [- .env.workspace.$INSTANCE_NAME]

  Security groups and key pair were kept (shared resources).

  To re-provision:
    /provision
```

For **full teardown**:
```
Teardown complete.

  Deleted:
    - Instance: i-xxx
    - Security group: sg-xxx
    [- Key pair: claude-dev-key]
    - .env.workspace.*

  To re-provision:
    /provision
```

---

## Error handling

- **No resources found**: tell the user, check region
- **Security group deletion fails**: instance may still be terminating — wait and retry
- **Named instance not found**: list existing instances and ask the user to pick one
- **Multiple instances found (no name given)**: list all, ask which to delete or all

Do NOT delete anything without explicit user confirmation.
