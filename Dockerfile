FROM ubuntu:24.04

LABEL org.opencontainers.image.source="https://github.com/verkyyi/always-on-claude"
LABEL org.opencontainers.image.description="Always-on Claude Code workspace — Ubuntu 24.04 + Node 22 + dev tools"

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/home/dev/.local/bin:${PATH}"

# System packages — ripgrep, fzf, and zsh are required by Claude Code
RUN apt-get update && apt-get install -y \
    curl git tmux vim jq unzip \
    build-essential python3 python3-pip \
    ripgrep fzf zsh \
    && rm -rf /var/lib/apt/lists/*

# Node.js 22.x LTS
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# AWS CLI v2
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "awscliv2.zip" \
    && unzip awscliv2.zip && ./aws/install \
    && rm -rf aws awscliv2.zip

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Non-root user (Claude Code refuses to run as root)
# Pre-create .claude dirs to prevent ENOENT crashes when Docker volumes mount as root
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupadd -g 1000 dev && useradd -m -s /bin/bash -u 1000 -g 1000 dev \
    && mkdir -p /home/dev/.claude/debug \
    && touch /home/dev/.claude/remote-settings.json \
    && chown -R dev:dev /home/dev/.claude

USER dev
WORKDIR /home/dev

# Bun — fast JS runtime/package manager used by many projects
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/home/dev/.bun/bin:${PATH}"

# Shell aliases
RUN cat >> /home/dev/.bashrc <<'EOF'

alias cc="claude --dangerously-skip-permissions"
alias gs="git status"
alias gl="git log --oneline -20"
EOF

# Claude Code — native installer, must run as non-root
# Placed last because the remote install script is unpinned and changes frequently,
# which would bust the Docker build cache for all subsequent layers
RUN curl -fsSL https://claude.ai/install.sh | bash

CMD ["bash"]
