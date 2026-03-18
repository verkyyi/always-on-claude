You are tearing down an always-on Claude Code workspace on AWS. Confirm with the user before deleting anything.

## Context

- AWS CLI configured: !`aws sts get-caller-identity 2>&1 | head -5`
- AWS region: !`aws configure get region 2>/dev/null || echo "not set"`
- Tagged instances: !`aws ec2 describe-instances --filters "Name=tag:Project,Values=always-on-claude" "Name=instance-state-name,Values=running,stopped,pending" --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress,Tags[?Key==\x60Name\x60].Value|[0],InstanceType]' --output text 2>/dev/null || echo "error — check AWS CLI"`
- Tagged security groups: !`aws ec2 describe-security-groups --filters "Name=tag:Project,Values=always-on-claude" --query 'SecurityGroups[].[GroupId,GroupName]' --output text 2>/dev/null || echo "none"`
- SSH key pairs: !`aws ec2 describe-key-pairs --query 'KeyPairs[].KeyName' --output text 2>/dev/null || echo "error"`
- Local .pem files: !`ls ~/.ssh/*.pem 2>/dev/null || echo "none"`

---

## Before you start

If the AWS CLI context above shows an error, stop and help the user configure it first.

---

## Step 1 — Show what will be deleted

List everything found with the `Project=always-on-claude` tag:

```
I found these resources:

  Instances:       i-xxx (1.2.3.4, claude-dev, t3.medium)
  Security groups: sg-xxx (claude-dev-sg)
  Key pair:        claude-dev-key (in AWS + local file)

Delete all of these? [y/N]
```

If nothing is found, say so and exit.

---

## Step 2 — Terminate instances

```bash
aws ec2 terminate-instances --region "$REGION" --instance-ids $INSTANCE_IDS
aws ec2 wait instance-terminated --region "$REGION" --instance-ids $INSTANCE_IDS
```

---

## Step 3 — Delete security groups

```bash
aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID"
```

If deletion fails (still in use from terminating instance), wait a moment and retry.

---

## Step 4 — Delete SSH key pair (ask separately)

```
Also delete the SSH key pair "claude-dev-key"? [y/N]
```

If yes:
```bash
aws ec2 delete-key-pair --region "$REGION" --key-name "$KEY_NAME"
rm -f ~/.ssh/$KEY_NAME.pem
```

---

## Step 5 — Summary

```
Teardown complete.

  Deleted:
    - Instance: i-xxx
    - Security group: sg-xxx
    [- Key pair: claude-dev-key]

  To re-provision:
    /provision
```

---

## Error handling

- **No resources found**: tell the user, check region
- **Security group deletion fails**: instance may still be terminating — wait and retry
- **Multiple instances found**: list all, ask which to delete or all

Do NOT delete anything without explicit user confirmation.
