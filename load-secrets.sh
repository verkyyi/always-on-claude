#!/bin/bash
# load-secrets.sh — Source this to pull secrets from AWS SSM Parameter Store.
# The EC2 instance role provides credentials automatically.
#
# Usage:
#   source ~/dev-env/load-secrets.sh
#
# Add your own parameters below. Store them first with:
#   aws ssm put-parameter --name "/myproject/key-name" --value "secret" --type SecureString

# Example:
# export MY_API_KEY=$(aws ssm get-parameter --name "/myproject/api-key" --with-decryption --query 'Parameter.Value' --output text)
# export SMTP_PASSWORD=$(aws ssm get-parameter --name "/myproject/smtp-pass" --with-decryption --query 'Parameter.Value' --output text)

echo "Secrets loaded from SSM Parameter Store."
