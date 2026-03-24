FROM ubuntu:24.04

LABEL org.opencontainers.image.source="https://github.com/verkyyi/always-on-claude"
LABEL org.opencontainers.image.description="Always-on Claude Code workspace — Ubuntu 24.04 + Node 22 + dev tools"

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/home/dev/.local/bin:${PATH}"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# System packages — ripgrep, fzf, and zsh are required by Claude Code
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git tmux vim jq unzip ca-certificates gnupg \
    build-essential python3 python3-pip \
    ripgrep fzf zsh \
    && rm -rf /var/lib/apt/lists/*

# Node.js 22.x LTS
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
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
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Non-root user (Claude Code refuses to run as root)
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupadd -g 1000 dev && useradd -m -s /bin/bash -u 1000 -g 1000 dev

# Claude Code — native installer, must run as non-root
USER dev
RUN curl -fsSL https://claude.ai/install.sh | bash
USER root

# Pre-create .claude dirs — Docker volumes mount as root and can
# overwrite ownership, causing ENOENT crashes without these
RUN mkdir -p /home/dev/.claude/debug \
    && touch /home/dev/.claude/remote-settings.json \
    && chown -R dev:dev /home/dev/.claude

USER dev
WORKDIR /home/dev

# Bun — fast JS runtime/package manager used by many projects
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/home/dev/.bun/bin:${PATH}"

# uv — Python package manager, provides uvx for running MCP servers
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Shell aliases
RUN printf '\nalias cc="claude --dangerously-skip-permissions"\nalias gs="git status"\nalias gl="git log --oneline -20"\n' >> /home/dev/.bashrc

CMD ["bash"]
