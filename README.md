# ClaudeBox

Run [Claude Code](https://github.com/anthropics/claude-code) inside a throwaway Docker
container. The agent runs with `--dangerously-skip-permissions` (no per-action approval
prompts), but it can only see what you explicitly mount — your real home directory and the
rest of your filesystem stay untouched.

The container is built on `node:lts-alpine` and ships with `git`, `bash`, `curl`,
[RTK](https://github.com/rtk-ai/rtk) (a token-saving command wrapper, telemetry disabled),
and the Claude Code CLI. It runs as a non-root `claude` user because Claude Code refuses to
run as root when permissions are skipped.

## Why use this?

- **Run Claude Code unattended.** `--dangerously-skip-permissions` lets the agent act without
  stopping to ask, which is convenient but risky on your real machine. A container bounds the
  blast radius to the directory you mount.
- **Keep your host config clean.** Container state (sessions, history, caches) lands in the
  project-local `claude-home/` folder instead of your real `~/.claude`.
- **Reproducible environment.** Everyone gets the same Node, git, and CLI versions regardless
  of what's installed on the host.

## Table of contents

- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Usage](#usage)
- [How authentication works](#how-authentication-works)
- [How it works](#how-it-works)
- [What's mounted](#whats-mounted)
- [Customization](#customization)
- [Project layout](#project-layout)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Security notes](#security-notes)

## Prerequisites

- **Docker** — any Docker-compatible engine works. Two common options:
  - [**Rancher Desktop**](https://rancherdesktop.io/) — free and open-source (SUSE). Bundles a
    Docker-compatible CLI and runtime; a good default if you want no licensing strings.
  - [**Docker Desktop**](https://www.docker.com/products/docker-desktop/) — free for personal
    use, education, and small businesses, but larger organizations need a paid subscription.

  Either way, make sure the engine is installed and its daemon is running before you launch.
- **Auth** — either an `ANTHROPIC_API_KEY` environment variable, or an existing Claude Code
  login on your host (`~/.claude/.credentials.json`).

> **Architecture note:** the image pulls the `x86_64` (amd64) build of RTK. On Apple Silicon
> or other ARM hosts it runs under emulation. See [Troubleshooting](#troubleshooting).

## Quick start

```bash
# 1. Clone
git clone https://github.com/riddlemd/ClaudeBox.git

# 2. From the project you want Claude to work on, launch the sandbox.
#    The image builds automatically on first run (one-time, a few minutes).

# Linux / macOS
/path/to/ClaudeBox/run.sh

# Windows (PowerShell)
C:\path\to\ClaudeBox\run.ps1
```

That's it — Claude Code starts in the container with your current directory mounted at
`/workspace`. Exit with `Ctrl-C` or `/exit`; the container is removed automatically (`--rm`).

## Usage

There are three entry points. They all build the same image and mount your current directory
to `/workspace` inside the container.

### Windows (PowerShell)

```powershell
# From the project you want to work on:
C:\path\to\ClaudeBox\run.ps1

# Or point it at a specific directory:
C:\path\to\ClaudeBox\run.ps1 -ProjectPath C:\some\other\project
```

The image is built automatically if it doesn't exist yet.

### Linux / macOS

```bash
# From the project you want to work on:
/path/to/ClaudeBox/run.sh

# Pass a project path as the first argument:
/path/to/ClaudeBox/run.sh /some/other/project

# ...and optionally a custom host credentials path as the second:
/path/to/ClaudeBox/run.sh /some/other/project /path/to/.credentials.json
```

The image is built automatically if it doesn't exist yet.

### Docker Compose

```bash
# Mounts the current directory by default.
ANTHROPIC_API_KEY=sk-ant-... docker compose run --rm claude

# Override the mounted directory with WORKSPACE=
WORKSPACE=/some/other/project docker compose run --rm claude
```

### Building the image manually

The launchers build automatically, but you can build (or rebuild after editing the
`Dockerfile`) by hand:

```bash
docker build -t claude-sandbox .

# Force a clean rebuild, ignoring the layer cache:
docker build --no-cache -t claude-sandbox .
```

## How authentication works

There are **two credential strategies**, and which one applies depends on the entry point —
this is deliberate, because Docker Compose can't portably reference your host's `~/.claude`
across Windows, macOS, and Linux.

| Entry point          | Credential source                                                                 |
| -------------------- | --------------------------------------------------------------------------------- |
| `run.ps1` / `run.sh` | Your **live host login** — mounts `~/.claude/.credentials.json` (and `.claude.json`) read-only into the container, where `entrypoint.sh` copies them into place. Falls back to `ANTHROPIC_API_KEY` if no login exists. |
| `docker compose`     | The committed **`claude-home/` directory** is mounted as `~/.claude`, plus whatever `ANTHROPIC_API_KEY` you pass. It does not read your host `~/.claude`. |

If neither a credentials file nor `ANTHROPIC_API_KEY` is available, the run scripts exit with
an error before starting the container.

In both cases, `entrypoint.sh` also patches `~/.claude.json` so Claude Code sees
`installMethod: npm-global` and trusts `/workspace` without the interactive trust prompt.

## How it works

When a container starts, `entrypoint.sh` runs as root and does the following before handing
off to Claude Code:

1. **Fixes ownership** of `/home/claude/.claude`. Bind mounts (especially on Windows) appear
   root-owned inside the container; this lets the unprivileged `claude` user write to its
   config directory.
2. **Installs credentials** — if `/tmp/host-credentials.json` was mounted (run scripts), it's
   copied to `~/.claude/.credentials.json`.
3. **Patches `~/.claude.json`** — either by rewriting your mounted host copy (setting
   `installMethod: npm-global` and marking `/workspace` as trusted) or by writing a minimal
   fresh one. This skips Claude Code's first-run setup and trust prompts.
4. **Drops privileges** with `su-exec` to the `claude` user, disables RTK telemetry, installs
   the RTK hook, and finally launches:

   ```
   claude --dangerously-skip-permissions --add-dir /workspace
   ```

## What's mounted

| Host                          | Container                  | Purpose                                      |
| ----------------------------- | -------------------------- | -------------------------------------------- |
| Your project directory        | `/workspace`               | The code the agent works on.                 |
| `./claude-home`               | `/home/claude/.claude`     | Project-local Claude config, kept out of your real `~/.claude`. |
| `~/.claude/.credentials.json` | `/tmp/host-credentials.json` (read-only) | Your host login (run scripts only). |
| `~/.claude.json`              | `/tmp/host-claude.json` (read-only)      | Host setup state (run scripts only). |

## Customization

- **Persisted Claude config** lives in `claude-home/`. Edit `claude-home/settings.json` to
  change the container's theme, hooks, or other Claude Code settings; edit
  `claude-home/CLAUDE.md` to give the in-container agent standing instructions.
- **Installed tools** are defined in the `Dockerfile`. Add an `apk add` package or another
  `npm install -g` line, then rebuild with `docker build -t claude-sandbox .`.
- **RTK version** is pinned in the `Dockerfile` (`v0.42.3`). Bump the URL to upgrade.
- **Default mounted directory** for Compose is controlled by the `WORKSPACE` variable in
  `docker-compose.yml`.

## Project layout

| File / dir           | Role                                                              |
| -------------------- | ---------------------------------------------------------------- |
| `Dockerfile`         | Builds the Alpine image with Node, git, RTK, and Claude Code.    |
| `entrypoint.sh`      | Fixes mount ownership, places credentials, drops to the `claude` user, launches Claude Code. |
| `run.ps1`            | Windows launcher — builds the image if missing, mounts host login. |
| `run.sh`             | Linux/macOS launcher — same behavior as `run.ps1`.              |
| `docker-compose.yml` | Compose entry point using the committed `claude-home/` config.  |
| `claude-home/`       | Project-local Claude config mounted into the container. Config files (`settings.json`, `CLAUDE.md`) are tracked; runtime state (credentials, sessions, history, caches) is git-ignored. |
| `.dockerignore`      | Keeps `claude-home/`, docs, and `.git` out of the build context. |

## Troubleshooting

**`docker: command not found` / "Docker is required"**
Install and start Docker Desktop or Rancher Desktop. `run.ps1` checks for the `docker`
command and exits early with this message if it's missing.

**"Set ANTHROPIC_API_KEY or ensure ... exists"**
The launcher found neither a host credentials file nor an `ANTHROPIC_API_KEY`. Either log in
to Claude Code on your host first, or export the key:

```bash
export ANTHROPIC_API_KEY=sk-ant-...      # Linux/macOS
$env:ANTHROPIC_API_KEY = "sk-ant-..."    # PowerShell
```

**The agent can't see my files**
Only `/workspace` is mounted. Run the launcher *from* the directory you want Claude to work
on, or pass that directory explicitly (`run.sh /path`, `run.ps1 -ProjectPath C:\path`).

**Permission / ownership errors writing config**
`entrypoint.sh` chowns `~/.claude` on startup to handle root-owned bind mounts. If you still
hit this, make sure you're launching through the provided scripts (which mount `claude-home`
correctly) rather than a hand-rolled `docker run`.

**Slow start or "exec format error" on Apple Silicon / ARM**
The image installs the `x86_64` RTK binary, so on ARM hosts it runs under emulation. Ensure
your Docker setup has emulation enabled (Rosetta/QEMU), or swap the RTK download URL in the
`Dockerfile` for an `aarch64` build and rebuild.

**Changes to the `Dockerfile` aren't taking effect**
The launchers only build when the image is *absent*. After editing the `Dockerfile`, rebuild
explicitly: `docker build -t claude-sandbox .` (add `--no-cache` to bypass the layer cache).

## FAQ

**Is my host filesystem safe?**
The agent can only reach what's mounted: `/workspace` and the read-only credential files. It
cannot touch anything else on your machine.

**Where do sessions and history go?**
Into `claude-home/` on your host, which is mounted as the container's `~/.claude`. Runtime
state there is git-ignored.

**Does it work offline?**
No — Claude Code calls the Anthropic API. You need network access and valid credentials.

**Can I run multiple sandboxes at once?**
Yes. Each launcher invocation starts an independent `--rm` container. They share the same
`claude-home/` config directory, so avoid running concurrent sessions that fight over it.

## Security notes

- `claude-home/.credentials.json` and the rest of `claude-home/`'s runtime state (sessions,
  history, caches) are **git-ignored** — see `.gitignore`. Don't commit secrets.
- Host credentials are mounted **read-only** (`:ro`) into `/tmp`; the container copies them
  into place rather than writing back to your host.
- The agent only has access to what you mount. It cannot reach your host filesystem outside
  `/workspace` and the credential mounts above.
- `--dangerously-skip-permissions` means the agent acts without asking. The container is the
  safety boundary — don't mount directories you aren't willing to let it modify.

## License

Released under the [MIT License](LICENSE).
