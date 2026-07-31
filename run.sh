#!/usr/bin/env bash
set -euo pipefail

PROJECT_PATH="${1:-$(pwd)}"
HOST_CLAUDE_DIR="${2:-$HOME/.claude}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Base config source: repo (committed template), host (curated copy of ~/.claude), or empty.
# Credentials are copied from ~/.claude regardless of the base (see HOST_CREDS below).
CLAUDE_BASE="${CLAUDE_BASE:-repo}"

# Config files copied from the host when CLAUDE_BASE=host. Deliberately excludes runtime state
# (sessions/, projects/, history.jsonl), caches, credentials (mounted separately), and plugins/
# (often platform-specific binaries) so the container never sees more than your settings.
HOST_ALLOWLIST=(settings.json settings.local.json CLAUDE.md CLAUDE.local.md \
                agents commands skills hooks output-styles)

HOST_CREDS="$HOST_CLAUDE_DIR/.credentials.json"

# Single EXIT trap: both the staged host config and the exported Keychain credential are
# temp files, and a second `trap ... EXIT` would silently replace the first.
KEYCHAIN_CREDS=""
STAGING=""
cleanup() {
    [[ -n "$KEYCHAIN_CREDS" ]] && rm -f "$KEYCHAIN_CREDS"
    [[ -n "$STAGING" ]] && rm -rf "$STAGING"
    return 0
}
trap cleanup EXIT

# macOS keeps the login in the Keychain instead of ~/.claude/.credentials.json, so there is no
# file to mount. Export it to a private temp file that cleanup() removes when the container exits.
if [[ -z "${ANTHROPIC_API_KEY:-}" ]] && [[ ! -f "$HOST_CREDS" ]] && [[ "$(uname -s)" == Darwin ]]; then
    KEYCHAIN_CREDS="$(mktemp)"
    chmod 600 "$KEYCHAIN_CREDS"
    if security find-generic-password -s "Claude Code-credentials" -w > "$KEYCHAIN_CREDS" 2>/dev/null \
       && [[ -s "$KEYCHAIN_CREDS" ]]; then
        HOST_CREDS="$KEYCHAIN_CREDS"
    else
        echo "Error: no Claude Code credentials in the macOS Keychain. Run 'claude' on the host" \
             "to log in, or set ANTHROPIC_API_KEY." >&2
        exit 1
    fi
fi

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
    # -L dereferences symlinks nested inside agents/, skills/ etc. Copying the links verbatim
    # would leave them dangling in the container, since their targets aren't mounted.
    for item in "${HOST_ALLOWLIST[@]}"; do
        [[ -e "$HOST_CLAUDE_DIR/$item" ]] && cp -RL "$HOST_CLAUDE_DIR/$item" "$STAGING/"
    done
    DOCKER_ARGS+=(-v "${STAGING}:/opt/host-claude:ro")
    [[ -f "$HOME/.claude.json" ]] && DOCKER_ARGS+=(-v "$HOME/.claude.json:/tmp/host-claude.json:ro")
fi

docker run -it --rm \
    "${DOCKER_ARGS[@]}" \
    -v "${PROJECT_PATH}:/workspace" \
    claude-sandbox
