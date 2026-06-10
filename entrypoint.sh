#!/usr/bin/env bash
set -euo pipefail

# Which base seeds the container's config:
#   repo  - the committed claude-default/ template baked into the image (default)
#   host  - a curated copy of your real ~/.claude, staged read-only by the run scripts
#   empty - a clean sandbox
CLAUDE_BASE="${CLAUDE_BASE:-repo}"
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

# Persistent "ClaudeBox" footer: inject a statusLine into settings.json (merging with whatever
# the base seeded). Done for every base so the indicator always shows, and it bakes in the
# resolved CLAUDE_BASE. \x27 is the single quote that wraps printf's argument.
CLAUDE_BASE="$CLAUDE_BASE" node -e '
const fs = require("fs");
const p = "/home/claude/.claude/settings.json";
let s = {};
try { s = JSON.parse(fs.readFileSync(p, "utf8")); } catch (e) {}
const base = process.env.CLAUDE_BASE || "repo";
s.statusLine = { type: "command", command: "printf \x27📦 ClaudeBox · base=" + base + " · sandboxed\x27" };
fs.writeFileSync(p, JSON.stringify(s, null, 2));
'

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

# ClaudeBox header: set the window title and print the wordmark just before Claude Code starts.
# Title and color are applied only on a real terminal so piped/no-color output stays clean.
if [ -t 1 ]; then
    printf '\033]0;ClaudeBox\007'        # window title
    CB_C=$'\033[36m'; CB_D=$'\033[2m'; CB_R=$'\033[0m'
else
    CB_C=''; CB_D=''; CB_R=''
fi
printf '%s' "$CB_C"
cat <<'BANNER'
 ██████╗██╗      █████╗ ██╗   ██╗██████╗ ███████╗██████╗  ██████╗ ██╗  ██╗
██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗██╔════╝██╔══██╗██╔═══██╗╚██╗██╔╝
██║     ██║     ███████║██║   ██║██║  ██║█████╗  ██████╔╝██║   ██║ ╚███╔╝
██║     ██║     ██╔══██║██║   ██║██║  ██║██╔══╝  ██╔══██╗██║   ██║ ██╔██╗
╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝███████╗██████╔╝╚██████╔╝██╔╝ ██╗
 ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝╚═════╝  ╚═════╝ ╚═╝  ╚═╝
BANNER
printf '%s%s        sandboxed Claude Code — your host filesystem is isolated%s\n\n' "$CB_R" "$CB_D" "$CB_R"

exec su-exec claude bash -c '
  rtk telemetry disable >/dev/null 2>&1
  rtk init -g --auto-patch >/dev/null 2>&1
  exec claude --dangerously-skip-permissions --add-dir /workspace
'
