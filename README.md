# ClaudeBox

Run [Claude Code](https://github.com/anthropics/claude-code) inside a throwaway Docker
container. The agent runs with `--dangerously-skip-permissions` but can only see what you
explicitly mount — your real home directory and the rest of your filesystem stay untouched.

The container is built on `node:lts-alpine` and ships with `git`, `bash`, `curl`,
[RTK](https://github.com/rtk-ai/rtk) (token-saving command wrapper, telemetry disabled), and
the Claude Code CLI. It runs as a non-root `claude` user because Claude Code refuses to run
as root when permissions are skipped.

## Prerequisites

- **Docker** — [Docker Desktop](https://www.docker.com/products/docker-desktop/) or
  [Rancher Desktop](https://rancherdesktop.io/).
- **Auth** — either an `ANTHROPIC_API_KEY` environment variable, or an existing Claude Code
  login on your host (`~/.claude/.credentials.json`).

## Usage

There are three entry points. They all build the same image and mount your current directory
to `/workspace` inside the container. The image is built automatically on first run.

### Windows (PowerShell)

```powershell
# From the project you want to work on:
C:\path\to\ClaudeBox\run.ps1

# Or point it at a specific directory:
C:\path\to\ClaudeBox\run.ps1 -ProjectPath C:\some\other\project
```

### Linux / macOS

```bash
# From the project you want to work on:
/path/to/ClaudeBox/run.sh

# Or pass a project path (and optionally a credentials path):
/path/to/ClaudeBox/run.sh /some/other/project
```

### Docker Compose

```bash
# Mounts the current directory by default; override with WORKSPACE=
ANTHROPIC_API_KEY=sk-ant-... docker compose run --rm claude
WORKSPACE=/some/other/project docker compose run --rm claude
```

## How authentication works

There are **two credential strategies**, and which one applies depends on the entry point —
this is deliberate, because Docker Compose can't portably reference your host's `~/.claude`
across Windows, macOS, and Linux.

| Entry point          | Credential source                                                                 |
| -------------------- | --------------------------------------------------------------------------------- |
| `run.ps1` / `run.sh` | Your **live host login** — mounts `~/.claude/.credentials.json` (and `.claude.json`) read-only into the container, where `entrypoint.sh` copies them into place. Falls back to `ANTHROPIC_API_KEY` if no login exists. |
| `docker compose`     | The committed **`claude-home/` directory** is mounted as `~/.claude`, plus whatever `ANTHROPIC_API_KEY` you pass. It does not read your host `~/.claude`. |

In both cases, `entrypoint.sh` also patches `~/.claude.json` so Claude Code sees
`installMethod: npm-global` and trusts `/workspace` without the interactive trust prompt.

## What's mounted

| Host                          | Container                  | Purpose                                      |
| ----------------------------- | -------------------------- | -------------------------------------------- |
| Your project directory        | `/workspace`               | The code the agent works on.                 |
| `./claude-home`               | `/home/claude/.claude`     | Project-local Claude config, kept out of your real `~/.claude`. |
| `~/.claude/.credentials.json` | `/tmp/host-credentials.json` (read-only) | Your host login (run scripts only). |
| `~/.claude.json`              | `/tmp/host-claude.json` (read-only)      | Host setup state (run scripts only). |

## Files

| File                 | Role                                                              |
| -------------------- | ---------------------------------------------------------------- |
| `Dockerfile`         | Builds the Alpine image with Node, git, RTK, and Claude Code.    |
| `entrypoint.sh`      | Fixes mount ownership, places credentials, drops to the `claude` user, launches Claude Code. |
| `run.ps1`            | Windows launcher — builds the image if missing, mounts host login. |
| `run.sh`             | Linux/macOS launcher — same behavior as `run.ps1`.              |
| `docker-compose.yml` | Compose entry point using the committed `claude-home/` config.  |

## Security notes

- `claude-home/.credentials.json` and the rest of `claude-home/`'s runtime state (sessions,
  history, caches) are **git-ignored** — see `.gitignore`. Don't commit secrets.
- The agent only has access to what you mount. It cannot reach your host filesystem outside
  `/workspace` and the credential mounts above.
