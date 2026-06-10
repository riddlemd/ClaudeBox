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
# We patch three things so a freshly created container starts straight into Claude Code:
#   - installMethod -> npm-global (the host says "native", but we install via npm here)
#   - /workspace marked trusted        -> skips the folder-trust prompt
#   - bypassPermissionsModeAccepted    -> skips the one-time "Bypass Permissions mode" warning
# Without the last flag the warning reappears on every fresh container, since this file is
# regenerated each run.
if [[ -f /tmp/host-claude.json ]]; then
    node -e "
const fs = require('fs');
const c = JSON.parse(fs.readFileSync('/tmp/host-claude.json', 'utf8'));
c.installMethod = 'npm-global';
c.bypassPermissionsModeAccepted = true;
if (!c.projects) c.projects = {};
c.projects['/workspace'] = Object.assign(c.projects['/workspace'] || {}, { hasTrustDialogAccepted: true });
fs.writeFileSync('/home/claude/.claude.json', JSON.stringify(c));
"
else
    printf '{"firstStartTime":"%s","installMethod":"npm-global","bypassPermissionsModeAccepted":true,"projects":{"/workspace":{"hasTrustDialogAccepted":true}}}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" > /home/claude/.claude.json
fi
chown claude:claude /home/claude/.claude.json

exec su-exec claude bash -c '
  rtk telemetry disable >/dev/null 2>&1
  rtk init -g --auto-patch >/dev/null 2>&1
  exec claude --dangerously-skip-permissions --add-dir /workspace
'
