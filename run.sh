#!/usr/bin/env bash
set -euo pipefail

PROJECT_PATH="${1:-$(pwd)}"
HOST_CREDS="${2:-$HOME/.claude/.credentials.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${ANTHROPIC_API_KEY:-}" ]] && [[ ! -f "$HOST_CREDS" ]]; then
    echo "Error: set ANTHROPIC_API_KEY or ensure ~/.claude/.credentials.json exists" >&2
    exit 1
fi

CREDS_MOUNT=()
[[ -f "$HOST_CREDS" ]] && CREDS_MOUNT=(-v "${HOST_CREDS}:/tmp/host-credentials.json:ro")

CLAUDE_JSON_MOUNT=()
[[ -f "$HOME/.claude.json" ]] && CLAUDE_JSON_MOUNT=(-v "$HOME/.claude.json:/tmp/host-claude.json:ro")

docker run -it --rm \
    ${ANTHROPIC_API_KEY:+-e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"} \
    "${CREDS_MOUNT[@]}" \
    "${CLAUDE_JSON_MOUNT[@]}" \
    -v "${PROJECT_PATH}:/workspace" \
    -v "${SCRIPT_DIR}/claude-home:/home/claude/.claude" \
    claude-sandbox
