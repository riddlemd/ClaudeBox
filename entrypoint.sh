#!/usr/bin/env bash
set -euo pipefail

# Which base seeds the container's config:
#   host  - a curated copy of your real ~/.claude, staged read-only by the run scripts
#   repo  - the committed claude-default/ template baked into the image
#   empty - a clean sandbox
CLAUDE_BASE="${CLAUDE_BASE:-host}"
CLAUDE_DIR=/home/claude/.claude

# Copy a base directory's contents into the container's writable ~/.claude. The base is always
# read-only, so the container works on a copy — nothing is ever written back to host or repo.
seed_from() {
    local src="$1"
    [[ -d "$src" ]] || return 0
    cp -a "$src/." "$CLAUDE_DIR/" 2>/dev/null || true
}

case "$CLAUDE_BASE" in
    host)
        if [[ -d /opt/host-claude ]]; then
            seed_from /opt/host-claude
        else
            echo "[entrypoint] CLAUDE_BASE=host but no host config is mounted (expected with" \
                 "docker compose). Falling back to the repo default template." >&2
            CLAUDE_BASE=repo
            seed_from /opt/claude-defaults
        fi
        ;;
    repo)
        seed_from /opt/claude-defaults
        ;;
    empty)
        : # clean sandbox — seed nothing
        ;;
    *)
        echo "[entrypoint] Unknown CLAUDE_BASE='$CLAUDE_BASE'; using the repo default template." >&2
        CLAUDE_BASE=repo
        seed_from /opt/claude-defaults
        ;;
esac

# Credentials are installed independently of the base so any base can authenticate.
# The run scripts mount the host login read-only; we copy it into place.
if [[ -f /tmp/host-credentials.json ]]; then
    cp /tmp/host-credentials.json "$CLAUDE_DIR/.credentials.json"
fi

# ~/.claude is the container's own directory (not a mount), but the seed copy ran as root —
# hand it to the unprivileged claude user before it starts writing session state.
chown -R claude:claude "$CLAUDE_DIR"

# ~/.claude.json holds Claude Code's setup state (numStartups, feature flags, project trust).
# Only inherit the host's copy under the host base; for repo/empty write a minimal file so the
# sandbox doesn't carry over host projects, MCP servers, or trust decisions. In every case we
# set:
#   installMethod=npm-global  - the host says "native", but we install via npm here
#   hasCompletedOnboarding    - skips the first-run setup wizard (theme/login/etc.) so the
#                               container never asks the user for any details
#   /workspace trusted        - skips the folder-trust prompt
# (The theme itself is set in claude-default/settings.json, so no theme picker appears either.)
if [[ "$CLAUDE_BASE" == host && -f /tmp/host-claude.json ]]; then
    node -e "
const fs = require('fs');
const c = JSON.parse(fs.readFileSync('/tmp/host-claude.json', 'utf8'));
c.installMethod = 'npm-global';
c.hasCompletedOnboarding = true;
if (!c.projects) c.projects = {};
c.projects['/workspace'] = Object.assign(c.projects['/workspace'] || {}, { hasTrustDialogAccepted: true });
fs.writeFileSync('/home/claude/.claude.json', JSON.stringify(c));
"
else
    printf '{"firstStartTime":"%s","installMethod":"npm-global","hasCompletedOnboarding":true,"projects":{"/workspace":{"hasTrustDialogAccepted":true}}}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" > /home/claude/.claude.json
fi
chown claude:claude /home/claude/.claude.json

exec su-exec claude bash -c '
  rtk telemetry disable >/dev/null 2>&1
  rtk init -g --auto-patch >/dev/null 2>&1
  exec claude --dangerously-skip-permissions --add-dir /workspace
'
