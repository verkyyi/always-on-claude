# CI/CD

All workflows run via GitHub Actions.

## Docker image (`docker-publish.yml`)

Builds and pushes multi-arch Docker images to GHCR on push to main.

**Triggers**: Changes to `Dockerfile`, `Dockerfile.portable`, `docker-compose*.yml`, `scripts/portable/**`, or the workflow itself.

**Jobs:**

| Job | What it does |
|---|---|
| `build-and-push` | Build + push base image (`:latest` + git SHA tag) |
| `build-and-push-portable` | Build + push portable image (`:portable` + `portable-<sha>` tag) |
| `smoke-test` | Verify base image — tools, user, directories |
| `smoke-test-portable` | Verify portable image — tools, user, directories, scripts |

**Platforms**: `linux/amd64`, `linux/arm64`
**Registry**: `ghcr.io/verkyyi/always-on-claude`
**Cache**: GitHub Actions cache (GHA) for fast rebuilds

### Image tags

| Tag | Image | When |
|---|---|---|
| `latest` | Base image | Every push to main |
| `portable` | Portable image (base + Tailscale + cron/at + scripts) | Every push to main |
| `<sha>` | Base image | Every push to main |
| `portable-<sha>` | Portable image | Every push to main |
| `v1.0.0` (version tags) | Base image | On release |

### Smoke tests

Run after each image build to verify the published image works:

**Base image checks:**
- Critical tools present: `claude`, `codex`, `node`, `git`, `gh`, `rg`, `fzf`, `zsh`, `tmux`, `vim`, `jq`, `aws`, `python3`, `bun`, `curl`
- User is `dev` (UID 1000, GID 1000)
- `~/.claude/debug/` directory exists
- `~/.codex/` directory exists
- `~/.claude/remote-settings.json` exists

**Portable image checks** (all base checks plus):
- `tailscale` present
- `~/projects/`, `~/overnight/` directories exist
- `entrypoint.sh`, `start-claude-portable.sh` scripts present

## AMI build (`build-ami.yml`)

Builds pre-baked AMIs with Docker + Claude Code + Codex pre-installed for ~40-second provisioning.

**Triggers:**
- After Docker image publish completes successfully
- Changes to `scripts/deploy/install.sh`
- Manual dispatch

**Strategy**: Matrix build — arm64 and x86_64 in parallel.

| Architecture | Instance type | Base AMI |
|---|---|---|
| arm64 | t4g.small | Ubuntu 24.04 arm64 |
| x86_64 | t3.small | Ubuntu 24.04 amd64 |

**Flow:**

1. Create temp SSH key pair
2. Find latest Ubuntu 24.04 AMI for the architecture
3. Launch build instance with 20GB gp3 volume
4. Wait for SSH
5. Copy and run `install.sh` (NON_INTERACTIVE=1)
6. Clean instance for snapshot:
   - Remove SSH host keys
   - Clear cloud-init state
   - Delete bash history
   - Stop Docker container
7. Create AMI with name: `always-on-claude-YYYYMMDD-<arch>-<sha>`
8. Wait for AMI availability
9. Deregister old AMIs (keeps 1 per arch — 2 total, under 5 public AMI limit)
10. Delete associated snapshots of deregistered AMIs
11. Make new AMI public
12. Terminate build instance, delete temp key pair

**Required secrets:**

| Secret | Purpose |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM user for EC2/AMI operations |
| `AWS_SECRET_ACCESS_KEY` | IAM user for EC2/AMI operations |

**Required IAM permissions:**

`ec2:RunInstances`, `ec2:TerminateInstances`, `ec2:CreateImage`, `ec2:DeregisterImage`, `ec2:ModifyImageAttribute`, `ec2:DisableImageBlockPublicAccess`, `ec2:CreateKeyPair`, `ec2:DeleteKeyPair`, `ec2:DescribeImages`, `ec2:DescribeInstances`, `ec2:DescribeSecurityGroups`, `ec2:CreateSecurityGroup`, `ec2:AuthorizeSecurityGroupIngress`, `ec2:CreateTags`, `ec2:DescribeSnapshots`, `ec2:DeleteSnapshot`

## PR validation (`pr-validate.yml`)

Runs on all pull requests to main.

| Job | Tool | What it checks |
|---|---|---|
| `shellcheck` | ShellCheck | Bash script quality (severity: warning+) |
| `hadolint` | Hadolint | Dockerfile best practices |
| `compose-validate` | `docker compose config` | Compose file syntax (base + build override) |
| `markdownlint` | markdownlint-cli2 | Markdown formatting (continue-on-error) |

## Security scan (`security-scan.yml`)

**Triggers**: PRs, pushes to main, weekly schedule (Monday 6am UTC).

| Job | When | What it does |
|---|---|---|
| `gitleaks` | Always | Scans git history for leaked secrets |
| `trivy-fs` | PRs only | Filesystem scan for CRITICAL/HIGH vulnerabilities |
| `trivy-image` | Push + schedule | Scans published Docker image, uploads SARIF to GitHub Security |

## Release (`release.yml`)

**Triggers**: Push of `v*` tags, or manual dispatch with a tag name.

**Flow:**

1. Determine tag (from git tag or manual input)
2. Generate changelog from commits since previous tag
3. Create GitHub Release with changelog
4. Tag the Docker image with the version number (`latest` → `v1.0.0`)

## AWS cleanup sweeper (`aws-cleanup-sweeper.yml`)

Hourly job that cleans up orphaned test resources from CI runs.

**Targets** (tagged `Project=aoc-ci-test`):
- EC2 instances running > 30 minutes → terminated
- Orphaned security groups → deleted (skips if still in use)
- Key pairs with `aoc-ci-` prefix older than 30 minutes → deleted

**Environment**: `aws-integration-test` (uses OIDC role via `AWS_CI_ROLE_ARN`)

## Workflow dependency chain

```
Push to main (Dockerfile changes)
  → docker-publish.yml
    → build-and-push (base image)
      → smoke-test
      → build-and-push-portable
        → smoke-test-portable
    → build-ami.yml (triggered by workflow_run)
      → arm64 AMI build
      → x86_64 AMI build

Push to main (install.sh changes)
  → build-ami.yml (triggered by path)

Pull request
  → pr-validate.yml (shellcheck, hadolint, compose, markdown)
  → smoke-test.yml (Docker build + verify)
  → security-scan.yml (gitleaks, trivy-fs)

Tag push (v*)
  → release.yml (GitHub Release + Docker tag)

Hourly schedule
  → aws-cleanup-sweeper.yml

Weekly schedule
  → security-scan.yml (trivy-image)
```
