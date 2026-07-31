param(
    [string]$ProjectPath = (Get-Location).Path,
    # Base config source: repo (committed template), host (curated copy of ~/.claude), or empty.
    # Credentials are copied from ~/.claude regardless of the base.
    [string]$Base = $(if ($env:CLAUDE_BASE) { $env:CLAUDE_BASE } else { "repo" })
)

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker is required. Install Rancher Desktop or Docker Desktop."
    exit 1
}

function Build-Image([string]$Version = "latest") {
    docker build --build-arg "CLAUDE_VERSION=$Version" -t claude-sandbox $PSScriptRoot
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# Build on first run (or if the image was removed), otherwise keep Claude Code current. Both
# probes run inside the image, so the host needs nothing beyond Docker. Set
# CLAUDEBOX_SKIP_UPDATE_CHECK=1 to skip the registry round trip.
if (-not (docker images -q claude-sandbox)) {
    Write-Host "Building claude-sandbox image..."
    Build-Image "latest"
} elseif (-not $env:CLAUDEBOX_SKIP_UPDATE_CHECK) {
    $latest = (docker run --rm --entrypoint npm claude-sandbox `
               view '@anthropic-ai/claude-code' version 2>$null | Select-Object -Last 1)
    $installed = (docker run --rm --entrypoint claude claude-sandbox --version 2>$null `
                  | ForEach-Object { $_.Split(' ')[0] } | Select-Object -First 1)
    # Empty means offline or a registry hiccup — launch the image we already have rather than
    # blocking, and never rebuild on a probe we could not actually compare.
    if ($latest -and $installed -and ($latest -ne $installed)) {
        Write-Host "Claude Code $installed -> $latest; rebuilding..."
        Build-Image $latest
    }
}

$hostClaudeDir = Join-Path $env:USERPROFILE ".claude"
$credsSource   = Join-Path $hostClaudeDir ".credentials.json"
$claudeJson    = Join-Path $env:USERPROFILE ".claude.json"

if (-not (Test-Path $credsSource) -and -not $env:ANTHROPIC_API_KEY) {
    Write-Error "Set ANTHROPIC_API_KEY or ensure $credsSource exists"
    exit 1
}

# Config files copied from the host when -Base host. Deliberately excludes runtime state,
# caches, credentials (mounted separately), and plugins/ (often platform-specific binaries).
$hostAllowlist = @("settings.json", "settings.local.json", "CLAUDE.md", "CLAUDE.local.md",
                   "agents", "commands", "skills", "hooks", "output-styles")

$dockerArgs = @("run", "-it", "--rm",
    "-e", "CLAUDE_BASE=$Base",
    "-v", "${ProjectPath}:/workspace")

if ($env:ANTHROPIC_API_KEY) {
    $dockerArgs += "-e", "ANTHROPIC_API_KEY=$env:ANTHROPIC_API_KEY"
}
if (Test-Path $credsSource) {
    $dockerArgs += "-v", "${credsSource}:/tmp/host-credentials.json:ro"
}

$staging = $null
$code = 0
try {
    # Host base: stage a curated copy of the allowlist and mount THAT read-only, so the agent
    # can never read your full ~/.claude. Also inherit ~/.claude.json (setup state).
    if ($Base -eq "host" -and (Test-Path $hostClaudeDir)) {
        $staging = Join-Path $env:TEMP ("claudebox-" + [System.Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $staging | Out-Null
        foreach ($item in $hostAllowlist) {
            $src = Join-Path $hostClaudeDir $item
            if (Test-Path $src) {
                Copy-Item -Recurse -Force $src (Join-Path $staging (Split-Path $src -Leaf))
            }
        }
        $dockerArgs += "-v", "${staging}:/opt/host-claude:ro"
        if (Test-Path $claudeJson) {
            $dockerArgs += "-v", "${claudeJson}:/tmp/host-claude.json:ro"
        }
    }

    $dockerArgs += "claude-sandbox"
    docker @dockerArgs
    $code = $LASTEXITCODE
} finally {
    if ($staging -and (Test-Path $staging)) {
        Remove-Item -Recurse -Force $staging
    }
}

exit $code
