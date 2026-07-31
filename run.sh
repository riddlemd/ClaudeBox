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

build_image() {
    docker build --build-arg "CLAUDE_VERSION=${1:-latest}" -t claude-sandbox "$SCRIPT_DIR"
}

# Build on first run (or if the image was removed), otherwise keep Claude Code current. Both
# probes run inside the image, so the host needs nothing beyond Docker. Set
# CLAUDEBOX_SKIP_UPDATE_CHECK=1 to skip the ~0.4s registry round trip.
if [[ -z "$(docker images -q claude-sandbox 2>/dev/null)" ]]; then
    echo "Building claude-sandbox image..."
    build_image latest
elif [[ -z "${CLAUDEBOX_SKIP_UPDATE_CHECK:-}" ]]; then
    latest="$(docker run --rm --entrypoint npm claude-sandbox \
              view @anthropic-ai/claude-code version 2>/dev/null | tr -d '\r' | tail -1)"
    installed="$(docker run --rm --entrypoint claude claude-sandbox --version 2>/dev/null \
                 | awk '{print $1}')"
    # Empty means offline or a registry hiccup — launch the image we already have rather than
    # blocking, and never rebuild on a probe we could not actually compare.
    if [[ -n "$latest" && -n "$installed" && "$latest" != "$installed" ]]; then
        echo "Claude Code $installed -> $latest; rebuilding..."
        build_image "$latest"
    fi
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
