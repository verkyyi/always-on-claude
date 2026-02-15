#!/bin/bash
# bootstrap.sh — Run once on a fresh EC2 Ubuntu 24.04 instance.
# Installs Docker, tmux, Tailscale, and prepares for the dev container.
#
# Usage:
#   scp -i your-key.pem bootstrap.sh ubuntu@<ip>:~/
#   ssh -i your-key.pem ubuntu@<ip> 'bash ~/bootstrap.sh'

set -euo pipefail

echo "=== Updating system ==="
sudo apt-get update && sudo apt-get upgrade -y

echo "=== Installing Docker ==="
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker ubuntu

echo "=== Installing Docker Compose plugin ==="
sudo apt-get install -y docker-compose-plugin

echo "=== Installing tmux ==="
sudo apt-get install -y tmux

echo "=== Installing Tailscale ==="
curl -fsSL https://tailscale.com/install.sh | sh

echo "=== Setting up one-command Claude Code access ==="
chmod +x ~/dev-env/start-claude.sh

# Add SSH login menu to .bash_profile (only if not already present)
if ! grep -q "ssh-login.sh" ~/.bash_profile 2>/dev/null; then
    echo "" >> ~/.bash_profile
    echo "# Auto-launch Claude Code on SSH login" >> ~/.bash_profile
    echo "source ~/dev-env/ssh-login.sh" >> ~/.bash_profile
fi

echo ""
echo "============================================"
echo "  Bootstrap complete!"
echo "============================================"
echo ""
echo "Next steps:"
echo ""
echo "  1. Activate Tailscale (interactive — opens a browser URL):"
echo "       sudo tailscale up --ssh"
echo "       sudo tailscale set --hostname my-dev-server"
echo ""
echo "  2. Log out and back in so Docker group takes effect:"
echo "       exit"
echo "       ssh ubuntu@my-dev-server"
echo ""
echo "  3. Copy dev-env files to ~/dev-env on this machine:"
echo "       scp -r ./* ubuntu@my-dev-server:~/dev-env/"
echo ""
echo "  4. Build and start the container:"
echo "       cd ~/dev-env && docker compose up -d"
echo ""
echo "  5. Fix volume permissions:"
echo "       docker compose exec -u root dev bash -c 'chown -R dev:dev /home/dev/.claude /home/dev/project'"
echo ""
echo "  6. Enter the container and do one-time setup:"
echo "       docker compose exec dev bash"
echo "       # Then: gh auth login, git clone, claude login"
echo ""
echo "  After setup, every SSH login will show:"
echo ""
echo "    [1] Claude Code (3s)"
echo "    [2] Plain shell"
echo ""
echo "  Wait 3 seconds or press Enter → Claude Code."
echo "  Press 2 → normal shell."
echo ""
