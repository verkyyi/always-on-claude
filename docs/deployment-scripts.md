# Deployment Scripts

## provision.sh

Runs on your Mac. Creates an EC2 instance and waits for it to be ready.

**Flow:**
1. Checks for existing instance (reuses if found)
2. Creates/reuses SSH key pair and security group
3. Finds pre-built AMI (falls back to stock Ubuntu if not found)
4. Launches instance with User Data
5. Waits for SSH + container to be running
6. Prints connection details

**Env vars:**

| Var | Default | Purpose |
|---|---|---|
| `INSTANCE_NAME` | `claude-dev` | EC2 instance name tag |
| `KEY_NAME` | `claude-dev-key` | SSH key pair name |
| `AWS_REGION` | from `aws configure` | AWS region |
| `INSTANCE_TYPE` | `t3.medium` | EC2 instance type |

## destroy.sh

Finds all resources tagged `Project=always-on-claude` and deletes them with confirmation.

## install.sh

Runs on the server (or during AMI build). Sets up everything from a stock Ubuntu install.

**Env vars:**

| Var | Default | Purpose |
|---|---|---|
| `TAILSCALE` | `0` | Install Tailscale for VPN SSH |
| `OVERNIGHT` | `0` | Install at/cron for overnight tasks |
| `LOCAL_BUILD` | `0` | Build Docker image locally instead of pulling |
| `NON_INTERACTIVE` | `0` | Skip Phase 2 (auth), for User Data scripts |

## build-ami.sh

Runs locally or via GitHub Actions. Builds a pre-baked AMI.

**Flow:**
1. Launches a temp instance with stock Ubuntu
2. Runs install.sh via SSH
3. Cleans instance (removes SSH host keys, cloud-init state)
4. Snapshots AMI, makes it public
5. Terminates the temp instance

## setup-auth.sh

Runs inside the container. Walks through git config, `gh auth login`, and `claude login`. Idempotent — skips steps already done.
