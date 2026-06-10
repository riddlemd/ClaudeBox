param(
    [string]$ProjectPath = (Get-Location).Path
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

$claudeHome  = Join-Path $PSScriptRoot "claude-home"
$credsSource = Join-Path $env:USERPROFILE ".claude\.credentials.json"

$dockerArgs = @("run", "-it", "--rm",
    "-v", "${ProjectPath}:/workspace",
    "-v", "${claudeHome}:/home/claude/.claude")

if ($env:ANTHROPIC_API_KEY) {
    $dockerArgs += "-e", "ANTHROPIC_API_KEY=$env:ANTHROPIC_API_KEY"
}

if (Test-Path $credsSource) {
    $dockerArgs += "-v", "${credsSource}:/tmp/host-credentials.json:ro"
} elseif (-not $env:ANTHROPIC_API_KEY) {
    Write-Error "Set ANTHROPIC_API_KEY or ensure $credsSource exists"
    exit 1
}

$claudeJsonSource = Join-Path $env:USERPROFILE ".claude.json"
if (Test-Path $claudeJsonSource) {
    $dockerArgs += "-v", "${claudeJsonSource}:/tmp/host-claude.json:ro"
}

$dockerArgs += "claude-sandbox"
docker @dockerArgs
exit $LASTEXITCODE
