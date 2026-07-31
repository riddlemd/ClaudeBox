# Debian rather than Alpine: rtk ships no aarch64-musl build, so an Alpine base could only run
# rtk on arm64 under x86 emulation. Trixie specifically — rtk's aarch64 build needs GLIBC_2.39,
# and bookworm only has 2.36.
FROM node:lts-trixie-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends git bash curl ca-certificates gosu \
    && rm -rf /var/lib/apt/lists/*

# rtk's Linux releases are split by libc: amd64 is musl-only, arm64 is gnu-only. The musl
# build is static, so it runs fine here despite the glibc base.
ARG TARGETARCH
RUN case "$TARGETARCH" in \
        amd64) RTK_TARGET=x86_64-unknown-linux-musl ;; \
        arm64) RTK_TARGET=aarch64-unknown-linux-gnu ;; \
        *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/rtk-ai/rtk/releases/download/v0.42.3/rtk-${RTK_TARGET}.tar.gz" \
       | tar -xz -C /usr/local/bin \
    && chmod +x /usr/local/bin/rtk \
    && rtk --version

RUN npm install -g @anthropic-ai/claude-code

# Non-root user — claude --dangerously-skip-permissions refuses to run as root
RUN groupadd --system claude \
    && useradd --system --gid claude --create-home --home-dir /home/claude claude \
    && mkdir -p /home/claude/.claude /workspace \
    && chown -R claude:claude /home/claude /workspace

# Committed default config, baked in as the read-only "repo" base template. The entrypoint
# copies it (or a curated host config) into the container's writable ~/.claude at startup.
COPY claude-default/ /opt/claude-defaults/

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
