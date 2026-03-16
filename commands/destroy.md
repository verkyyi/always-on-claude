You are tearing down an always-on Claude Code workspace on AWS. Confirm with the user before deleting anything.

## Context

- AWS CLI configured: !`aws sts get-caller-identity 2>&1 | head -5`
- AWS region: !`aws configure get region 2>/dev/null || echo "not set"`
- CloudFormation stacks: !`aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE DELETE_FAILED --query 'StackSummaries[].[StackName,StackStatus]' --output text 2>/dev/null || echo "error — check AWS CLI"`
- SSH key pairs: !`aws ec2 describe-key-pairs --query 'KeyPairs[].KeyName' --output text 2>/dev/null || echo "error"`
- Local .pem files: !`ls ~/.ssh/*.pem 2>/dev/null || echo "none"`

---

## Before you start

If the AWS CLI context above shows an error, stop and help the user configure it first.

If `$ARGUMENTS` is provided, use it as the stack name. Otherwise, default to `claude-dev`.

---

## Step 1 — Show what will be deleted

Look at the context above and show the user exactly what exists:

```
I found these resources for stack "$STACK_NAME":

  CloudFormation stack: $STACK_NAME ($STATUS)
    - EC2 instance (will be terminated, EBS volume deleted)
    - Security group
  SSH key pair in AWS: $KEY_NAME
  Local key file: ~/.ssh/$KEY_NAME.pem

Delete all of these? [y/N]
```

If the stack doesn't exist, say so. If there are multiple stacks that look relevant, list them and ask which one.

---

## Step 2 — Delete CloudFormation stack

```bash
aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
```

Then wait for deletion:
```bash
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
```

Tell the user "Deleting stack... this takes 1-2 minutes." while waiting.

If the stack is in `DELETE_FAILED`, try again. If it fails twice, show the error and suggest manual cleanup in the AWS console.

---

## Step 3 — Delete SSH key pair (ask first)

```
Also delete the SSH key pair "$KEY_NAME"? [y/N]
```

If yes:
```bash
aws ec2 delete-key-pair --key-name "$KEY_NAME" --region "$REGION"
rm -f ~/.ssh/$KEY_NAME.pem
```

If no, tell the user the key pair remains in AWS and locally for future use.

---

## Step 4 — Summary

```
Teardown complete.

  Deleted:
    - CloudFormation stack: $STACK_NAME
    - EC2 instance + EBS volume
    - Security group
    [- SSH key pair: $KEY_NAME (if deleted)]

  To re-provision:
    /provision
```

---

## Error handling

- **Stack not found**: tell the user, check if they mean a different stack name or region
- **DELETE_FAILED**: show which resources failed to delete, suggest AWS console cleanup
- **Wrong region**: if no stack found in default region, check if the user meant another region

Do NOT delete anything without explicit user confirmation.
