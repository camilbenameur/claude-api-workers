# find-api-keys.ps1 - list the Anthropic API keys already present on this machine, MASKED.
# Never prints a full key: only a fingerprint (first 12 hex of SHA-256), the first 13 and last
# 4 characters, and where each key was found. Nothing leaves the machine unless -Check is given,
# which asks the Anthropic API (and only it) whether each key still works.
#
#   find-api-keys.ps1 [-Json] [-Check] [-Root dir1,dir2] [-MaxDepth 6] [-TimeoutSec 60]
#
# Looked at: environment variables (process, user, machine), Claude Code settings and
# ~/.claude.json, shell and PowerShell profiles, a few known tool configs, and .env-style
# files (.env, .env.*, *.env, .envrc) under the home folder, skipping dependency/cache folders.
# -PassThruSecret is internal (used by set-worker-key.ps1): it returns objects WITH the key.
param(
    [switch]$Json,
    [switch]$Check,
    [string[]]$Root,
    [int]$MaxDepth = 6,
    [int]$TimeoutSec = 60,
    [switch]$PassThruSecret
)
. "$PSScriptRoot\claude-worker-lib.ps1"

$homeDir = $env:USERPROFILE
# powershell -File passes "a,b" as one string: split it ourselves
$Root = @($Root | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if (-not $Root) { $Root = @($homeDir) }

$found = [ordered]@{}   # key -> list of places
function Add-Hit([string]$Value, [string]$Source) {
    if (-not $found.Contains($Value)) { $found[$Value] = New-Object System.Collections.Generic.List[string] }
    if (-not $found[$Value].Contains($Source)) { $found[$Value].Add($Source) }
}
function Search-Text([string]$Text, [string]$Source) {
    foreach ($m in [regex]::Matches($Text, $AnthropicKeyPattern)) { Add-Hit $m.Value $Source }
}
function Search-File([string]$Path, [long]$MaxBytes = 1MB) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.PSIsContainer -or $item.Length -gt $MaxBytes) { return }
    $n = 0
    foreach ($line in [IO.File]::ReadLines($item.FullName)) {
        $n++
        if ($line.Contains('sk-ant-api')) { Search-Text $line "file:$($item.FullName):$n" }
    }
}

# 1. Environment variables
foreach ($scope in 'Process', 'User', 'Machine') {
    $vars = [Environment]::GetEnvironmentVariables($scope)
    foreach ($name in $vars.Keys) { Search-Text ([string]$vars[$name]) "env:${scope}:$name" }
}

# 2. Known config files (big ones allowed: ~/.claude.json can weigh several MB)
$docs = [Environment]::GetFolderPath('MyDocuments')
$known = @(
    '.claude\settings.json', '.claude\settings.local.json', '.claude.json',
    '.env', '.envrc', '.bashrc', '.bash_profile', '.profile', '.zshrc', '.zshenv', '.zprofile',
    '.config\fish\config.fish', '.aider.conf.yml', '.continue\config.json', '.continue\config.yaml'
) | ForEach-Object { Join-Path $homeDir $_ }
$known += @(
    (Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $docs 'WindowsPowerShell\profile.ps1'),
    (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $docs 'PowerShell\profile.ps1')
)
if ($env:APPDATA) { $known += (Join-Path $env:APPDATA 'io.datasette.llm\keys.json') }
foreach ($path in $known) { Search-File $path 50MB }

# 3. .env-style files under the roots, breadth-first, without following junctions or symlinks
$skip = @('node_modules', '.git', '.hg', '.svn', '.venv', 'venv', '__pycache__', '.cache', '.npm', '.yarn',
    '.pnpm-store', '.cargo', '.rustup', '.gradle', '.m2', '.nuget', 'AppData', 'Library', '.Trash',
    'site-packages', '.next', '.nuxt', 'Pods', 'DerivedData', '$Recycle.Bin')
$envName = '^(\.env(\..+)?|.+\.env|\.envrc)$'
$clock = [Diagnostics.Stopwatch]::StartNew()
$dirs = 0; $truncated = $false
$queue = New-Object System.Collections.Generic.Queue[object]
foreach ($r in $Root) { if (Test-Path -LiteralPath $r -PathType Container) { $queue.Enqueue(@($r, 0)) } }
while ($queue.Count -gt 0) {
    if ($clock.Elapsed.TotalSeconds -gt $TimeoutSec) { $truncated = $true; break }
    $entry = $queue.Dequeue(); $dir = $entry[0]; $depth = $entry[1]
    $dirs++
    foreach ($child in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
        if ($child.PSIsContainer) {
            if ($child.LinkType -or $depth + 1 -gt $MaxDepth -or $skip -contains $child.Name) { continue }
            $queue.Enqueue(@($child.FullName, ($depth + 1)))
        }
        elseif ($child.Name -match $envName) { Search-File $child.FullName }
    }
}

# Report
$stored = Read-StoredKey
$candidates = foreach ($value in $found.Keys) {
    $c = [ordered]@{
        fingerprint = Get-KeyFingerprint $value
        masked      = Get-MaskedKey $value
        sources     = @($found[$value])
        status      = 'unchecked'
        stored      = ($stored -and $value -eq $stored)
    }
    if ($Check) { $c.status = Test-AnthropicKey $value }
    if ($PassThruSecret) { $c.key = $value }
    [pscustomobject]$c
}
$candidates = @($candidates)

if ($PassThruSecret) { return $candidates }

$summary = [ordered]@{
    candidates  = $candidates
    scanned     = [ordered]@{ roots = @($Root); directories = $dirs; max_depth = $MaxDepth; truncated = $truncated }
    stored_key  = if ($stored) { Get-KeyFingerprint $stored } else { $null }
}
if ($Json) {
    $summary | ConvertTo-Json -Depth 5
    return
}
if ($candidates.Count -eq 0) { Write-Output 'No Anthropic API key found.' }
else {
    Write-Output "Found $($candidates.Count) Anthropic API key(s), masked:"
    foreach ($c in $candidates) {
        $flags = @($c.status)
        if ($c.stored) { $flags += 'stored for claude-worker' }
        Write-Output ("  [{0}] {1}  ({2})" -f $c.fingerprint, $c.masked, ($flags -join ', '))
        foreach ($s in $c.sources) { Write-Output "      $s" }
    }
}
if ($truncated) { Write-Output "Note: the folder scan stopped after $TimeoutSec s ($dirs folders); pass -Root to target a folder." }
