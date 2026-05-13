# =============================================================================
# claude-agent Dockerfile
# Builds a container image with Claude Code CLI installed.
# Runs as non-root user (required by Claude Code --dangerously-skip-permissions)
# =============================================================================

FROM node:20-slim
ARG BUILD_DATE=unknown
LABEL build-date=$BUILD_DATE

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    git \
    jq \
    python3 \
    python3-pip \
    ca-certificates \
    openssl \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI globally
RUN npm install -g @anthropic-ai/claude-code

# Install Python Anthropic SDK as fallback
RUN pip3 install anthropic pg8000 --break-system-packages

# Create non-root user — Claude Code requires this
RUN useradd -m -u 1001 -s /bin/bash agent

# Create working directories and set ownership
RUN mkdir -p /agent /memory/inbox /memory/specs /memory/queue \
             /memory/workspace /memory/reviews /memory/deployments \
             /memory/logs /etc/agent \
    && chown -R agent:agent /agent /memory

# Copy scripts and base agent instructions
COPY --chown=agent:agent entrypoint.sh /agent/entrypoint.sh
COPY --chown=agent:agent queue-watcher.sh /agent/queue-watcher.sh
COPY --chown=agent:agent agent-base.md /agent/CLAUDE.md
RUN chmod +x /agent/entrypoint.sh /agent/queue-watcher.sh

# Switch to non-root user
USER agent
WORKDIR /agent

ENV ANTHROPIC_API_KEY=""
ENV AGENT_ROLE=""
ENV MEMORY_PATH="/memory"
ENV MAX_TOKENS="4096"
ENV AGENT_TIMEOUT="300"

ENTRYPOINT ["/agent/entrypoint.sh"]
