param(
    [string]$ProjectPath = (Get-Location).Path,
    # Base config source: host (curated copy of ~/.claude), repo (committed template), or empty.
    [string]$Base = $(if ($env:CLAUDE_BASE) { $env:CLAUDE_BASE } else { "host" })
)

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker is required. Install Rancher Desktop or Docker Desktop."
    exit 1
}

# Build the image on first run (or if it was removed).
if (-not (docker images -q claude-sandbox)) {
    Write-Host "Building claude-sandbox image..."
    docker build -t claude-sandbox $PSScriptRoot
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
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
