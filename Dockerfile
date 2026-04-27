FROM node:22-slim

ARG UID=1000
ARG GID=1000

# Install only what the entrypoint and Claude Code actually need:
#   tmux            - the entrypoint terminal multiplexer
#   git             - Claude Code's git tooling
#   ca-certificates - HTTPS for npm + Anthropic API
#   ripgrep         - fast code search used by Claude
#   less, procps    - basic shell ergonomics inside the shell window
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tmux git ca-certificates ripgrep less procps rclone \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

# Non-root user. UID/GID match host (1000/1000) by default; override with
# --build-arg UID=... --build-arg GID=... if your host UID differs.
# node:* base images pre-create a `node` user at UID/GID 1000 — remove it first
# so we can claim those IDs for claude-runner. Idempotent if `node` is absent.
RUN userdel -r node 2>/dev/null || true \
 && groupdel node 2>/dev/null || true \
 && groupadd -g "$GID" claude-runner \
 && useradd  -m -u "$UID" -g "$GID" -s /bin/bash claude-runner

# tmux config and entrypoint script (real files in build context).
COPY --chown=claude-runner:claude-runner tmux.conf /home/claude-runner/.tmux.conf
COPY cdocker-entrypoint /usr/local/bin/cdocker-entrypoint
RUN chmod +x /usr/local/bin/cdocker-entrypoint

USER claude-runner
ENV TERM=xterm-256color
ENV HOME=/home/claude-runner
WORKDIR /home/claude-runner
ENTRYPOINT ["/usr/local/bin/cdocker-entrypoint"]
