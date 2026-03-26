# CI/CD Pipelines

## Docker image (`.github/workflows/docker-publish.yml`)

Builds and pushes a multi-arch Docker image to GHCR on push to main.

- **Triggers**: Changes to `Dockerfile`, `docker-compose.yml`, or the workflow
- **Platforms**: linux/amd64, linux/arm64
- **Registry**: `ghcr.io/verkyyi/always-on-claude:latest`
- **Tags**: `latest` + git SHA
- **Cache**: GitHub Actions cache for fast rebuilds

## AMI build (`.github/workflows/build-ami.yml`)

Builds pre-baked AMIs for both arm64 and x86_64 with everything pre-installed for ~40s provisioning.

- **Triggers**: After Docker image publish, changes to `install.sh`, or manual dispatch
- **Architectures**: arm64 (t4g.small) and x86_64 (t3.small) built in parallel via matrix strategy
- **Process**: Launch temp EC2 → run install.sh → snapshot AMI → clean up old AMIs → make public → terminate
- **Tag**: `Project=always-on-claude` (provision.sh finds AMIs by this tag + architecture)
- **Region**: us-east-1 (copy to other regions manually)
- **Cleanup**: Automatically deregisters old AMIs per architecture (keeps 1 per arch) to stay under the 5 public AMI quota

### Required secrets

| Secret | Purpose |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM user for EC2/AMI operations |
| `AWS_SECRET_ACCESS_KEY` | IAM user for EC2/AMI operations |

### IAM permissions needed

`ec2:RunInstances`, `ec2:TerminateInstances`, `ec2:CreateImage`, `ec2:DeregisterImage`, `ec2:ModifyImageAttribute`, `ec2:DisableImageBlockPublicAccess`, `ec2:CreateKeyPair`, `ec2:DeleteKeyPair`, `ec2:DescribeImages`, `ec2:DescribeInstances`, `ec2:DescribeSecurityGroups`, `ec2:CreateSecurityGroup`, `ec2:AuthorizeSecurityGroupIngress`, `ec2:CreateTags`, `ec2:DescribeSnapshots`, `ec2:CreateSnapshot`, `ec2:DeleteSnapshot`
