# Cost Visibility

You are showing estimated infrastructure costs for an always-on Claude Code workspace and optionally setting up auto-stop scheduling to save money.

## Environment check

First, check if this is a provisioned host:
```bash
test -f ~/dev-env/.provisioned && echo "provisioned" || echo "not provisioned"
```

If "not provisioned", tell the user:
"This command is only available on a provisioned workspace. SSH into your instance first."
Then stop.

Next, detect workspace type:
```bash
source ~/dev-env/.env.workspace 2>/dev/null || true
echo "WORKSPACE_TYPE=${WORKSPACE_TYPE:-ec2}"
```

If `WORKSPACE_TYPE` is `local-mac`, tell the user:
"Cost tracking is only available for EC2 workspaces. Your local Mac workspace has no hourly cloud costs."
Then stop.

---

## Step 1 — Show current costs

Run the cost estimation script:
```bash
bash ~/dev-env/scripts/runtime/cost.sh
```

Present the output to the user clearly.

---

## Step 2 — Offer cost-saving options

After showing costs, offer these options:

```
What would you like to do?

  [1] Set up auto-stop schedule (save ~60% by stopping overnight)
  [2] View/change auto-stop schedule
  [3] Just viewing — done

```

---

## Step 3 — Auto-stop scheduling (if chosen)

If the user wants to set up auto-stop, ask for their preferred schedule:

```
When should the instance stop and start?

  Stop at:  midnight (00:00 UTC)
  Start at: 8:00 AM (08:00 UTC)

Tell me your preferred times, or press Enter for defaults.
Tip: use your local timezone — I'll convert to UTC.
```

Once confirmed, run the auto-stop script:
```bash
bash ~/dev-env/scripts/runtime/auto-stop.sh --stop HH:MM --start HH:MM
```

If the user wants to view the current schedule:
```bash
bash ~/dev-env/scripts/runtime/auto-stop.sh --status
```

If the user wants to remove the schedule:
```bash
bash ~/dev-env/scripts/runtime/auto-stop.sh --remove
```

---

## Step 4 — Suggest further savings

Based on the instance type, suggest alternatives if applicable:

- If running `t3.*`, suggest the `t4g.*` equivalent (Graviton, ~20% cheaper)
- If running a larger instance (medium/large), mention that Claude Code runs fine on `t4g.small`
- Mention that stopped instances only pay for EBS storage (~$1.60/mo for 20GB)

---

## Important

- This runs on the **host**, not inside the container
- All costs are estimates based on us-east-1 on-demand pricing
- Auto-stop uses cron on the host + AWS CLI to stop the instance
- Auto-start uses EventBridge Scheduler to start the instance (requires IAM permissions)
- The instance must have IAM permissions to stop itself and create EventBridge rules
