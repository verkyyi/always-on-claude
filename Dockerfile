FROM ubuntu:24.04

LABEL org.opencontainers.image.source="https://github.com/verkyyi/always-on-claude"
LABEL org.opencontainers.image.description="Always-on AI coding workspace — Ubuntu 24.04 + Claude Code + Codex + dev tools"

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

# Playwright + Codex
RUN npm install -g playwright @openai/codex \
    && apt-get update \
    && playwright install-deps chromium \
    && rm -rf /var/lib/apt/lists/*
ENV NODE_PATH=/usr/lib/node_modules

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

# Pre-create runtime dirs — Docker volumes mount as root and can
# overwrite ownership, causing ENOENT crashes without these
RUN mkdir -p /home/dev/.claude/debug \
    && mkdir -p /home/dev/.codex \
    && touch /home/dev/.claude/remote-settings.json \
    && chown -R dev:dev /home/dev/.claude /home/dev/.codex

USER dev
WORKDIR /home/dev

# Bun — fast JS runtime/package manager used by many projects
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/home/dev/.bun/bin:${PATH}"

# uv — Python package manager, provides uvx for running MCP servers
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Pre-cache MCP server packages so first Claude Code launch is fast
# (without this, npx/uvx download on first run, delaying the theme selector)
RUN npx -y @upstash/context7-mcp --help >/dev/null 2>&1 || true
RUN /home/dev/.local/bin/uvx mcp-server-fetch --help >/dev/null 2>&1 || true
RUN npx -y @playwright/mcp --help >/dev/null 2>&1 || true

# Pre-download Chromium browser — avoids ~150MB download on first use
RUN playwright install chromium

# Shell aliases
RUN printf '\nalias cc="claude --dangerously-skip-permissions"\nalias cx="codex --dangerously-bypass-approvals-and-sandbox"\nalias gs="git status"\nalias gl="git log --oneline -20"\n' >> /home/dev/.bashrc

# Auto-install per-project Python deps on login (runs for `bash -lc` in cron jobs)
# Uses a cache marker so re-install only happens when requirements.txt changes.
# hadolint ignore=SC2016
RUN printf '\n# Auto-install per-project Python requirements\nfor _req in "$HOME"/projects/*/requirements.txt; do\n    [ -f "$_req" ] || continue\n    _marker="$HOME/.cache/aoc/$(basename "$(dirname "$_req")").installed"\n    if [ ! -f "$_marker" ] || [ "$_req" -nt "$_marker" ]; then\n        mkdir -p "$(dirname "$_marker")"\n        pip install -q --user --break-system-packages -r "$_req" >/dev/null 2>&1 && touch "$_marker" || true\n    fi\ndone\nunset _req _marker\n' >> /home/dev/.profile

CMD ["bash"]
