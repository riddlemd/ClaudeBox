#!/usr/bin/env bash
set -euo pipefail

# Windows bind mounts appear root-owned inside the container.
# Fix ownership before dropping privileges so the claude user can write to ~/.claude.
chown -R claude:claude /home/claude/.claude

if [[ -f /tmp/host-credentials.json ]]; then
    cp /tmp/host-credentials.json /home/claude/.claude/.credentials.json
    chown claude:claude /home/claude/.claude/.credentials.json
fi

# ~/.claude.json holds Claude Code's full setup state (numStartups, feature flags, etc.).
# Patch installMethod to npm-global — the host says "native" but we're npm-global in this container.
if [[ -f /tmp/host-claude.json ]]; then
    node -e "
const fs = require('fs');
const c = JSON.parse(fs.readFileSync('/tmp/host-claude.json', 'utf8'));
c.installMethod = 'npm-global';
if (!c.projects) c.projects = {};
c.projects['/workspace'] = Object.assign(c.projects['/workspace'] || {}, { hasTrustDialogAccepted: true });
fs.writeFileSync('/home/claude/.claude.json', JSON.stringify(c));
"
else
    printf '{"firstStartTime":"%s","installMethod":"npm-global","projects":{"/workspace":{"hasTrustDialogAccepted":true}}}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" > /home/claude/.claude.json
fi
chown claude:claude /home/claude/.claude.json

exec su-exec claude bash -c '
  rtk telemetry disable >/dev/null 2>&1
  rtk init -g --auto-patch >/dev/null 2>&1
  exec claude --dangerously-skip-permissions --add-dir /workspace
'
