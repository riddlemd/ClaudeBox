FROM node:lts-alpine

RUN apk add --no-cache git bash curl ca-certificates su-exec

# RTK musl binary — Alpine uses musl libc, this is the correct target
RUN curl -fsSL https://github.com/rtk-ai/rtk/releases/download/v0.42.3/rtk-x86_64-unknown-linux-musl.tar.gz \
    | tar -xz -C /usr/local/bin \
    && chmod +x /usr/local/bin/rtk

RUN npm install -g @anthropic-ai/claude-code

# Non-root user — claude --dangerously-skip-permissions refuses to run as root
RUN addgroup -S claude && adduser -S claude -G claude \
    && mkdir -p /home/claude/.claude /workspace \
    && chown -R claude:claude /home/claude /workspace

# Committed default config, baked in as the read-only "repo" base template. The entrypoint
# copies it (or a curated host config) into the container's writable ~/.claude at startup.
COPY claude-default/ /opt/claude-defaults/

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
