#!/usr/bin/env bash
set -euo pipefail

PROJECT_PATH="${1:-$(pwd)}"
HOST_CLAUDE_DIR="${2:-$HOME/.claude}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Base config source: host (curated copy of ~/.claude), repo (committed template), or empty.
CLAUDE_BASE="${CLAUDE_BASE:-host}"

# Config files copied from the host when CLAUDE_BASE=host. Deliberately excludes runtime state
# (sessions/, projects/, history.jsonl), caches, credentials (mounted separately), and plugins/
# (often platform-specific binaries) so the container never sees more than your settings.
HOST_ALLOWLIST=(settings.json settings.local.json CLAUDE.md CLAUDE.local.md \
                agents commands skills hooks output-styles)

HOST_CREDS="$HOST_CLAUDE_DIR/.credentials.json"

if [[ -z "${ANTHROPIC_API_KEY:-}" ]] && [[ ! -f "$HOST_CREDS" ]]; then
    echo "Error: set ANTHROPIC_API_KEY or ensure $HOST_CREDS exists" >&2
    exit 1
fi

# Build the image on first run (or if it was removed).
if [[ -z "$(docker images -q claude-sandbox 2>/dev/null)" ]]; then
    echo "Building claude-sandbox image..."
    docker build -t claude-sandbox "$SCRIPT_DIR"
fi

DOCKER_ARGS=(-e "CLAUDE_BASE=$CLAUDE_BASE")
[[ -n "${ANTHROPIC_API_KEY:-}" ]] && DOCKER_ARGS+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
[[ -f "$HOST_CREDS" ]] && DOCKER_ARGS+=(-v "${HOST_CREDS}:/tmp/host-credentials.json:ro")

# Host base: stage a curated copy of the allowlist in a temp dir and mount THAT read-only, so
# the agent can never read your full ~/.claude. Also inherit ~/.claude.json (setup state).
if [[ "$CLAUDE_BASE" == "host" ]] && [[ -d "$HOST_CLAUDE_DIR" ]]; then
    STAGING="$(mktemp -d)"
    trap 'rm -rf "$STAGING"' EXIT
    for item in "${HOST_ALLOWLIST[@]}"; do
        [[ -e "$HOST_CLAUDE_DIR/$item" ]] && cp -r "$HOST_CLAUDE_DIR/$item" "$STAGING/"
    done
    DOCKER_ARGS+=(-v "${STAGING}:/opt/host-claude:ro")
    [[ -f "$HOME/.claude.json" ]] && DOCKER_ARGS+=(-v "$HOME/.claude.json:/tmp/host-claude.json:ro")
fi

docker run -it --rm \
    "${DOCKER_ARGS[@]}" \
    -v "${PROJECT_PATH}:/workspace" \
    claude-sandbox
