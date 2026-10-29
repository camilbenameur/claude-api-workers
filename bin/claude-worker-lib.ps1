# Shared helpers for claude-worker.ps1, set-worker-key.ps1 and find-api-keys.ps1.
# Dot-source it: . "$PSScriptRoot\claude-worker-lib.ps1"
# Kept pure ASCII so Windows PowerShell 5.1 reads it the same with or without a BOM.

# Key store: DPAPI-encrypted, readable only by the current Windows user.
# CLAUDE_WORKER_HOME overrides the folder (tests, portable setups).
function Get-WorkerHome {
    if ($env:CLAUDE_WORKER_HOME) { return $env:CLAUDE_WORKER_HOME }
    return (Join-Path $env:LOCALAPPDATA 'claude-worker')
}

function Get-WorkerKeyPath { Join-Path (Get-WorkerHome) 'key.dat' }

# $null when no key is stored, '' when the file exists but cannot be decrypted
function Read-StoredKey {
    $file = Get-WorkerKeyPath
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    try {
        $secure = Get-Content -LiteralPath $file -ErrorAction Stop | ConvertTo-SecureString -ErrorAction Stop
        return [System.Net.NetworkCredential]::new('', $secure).Password
    }
    catch { return '' }
}

function Save-StoredKey([string]$Key) {
    New-Item -ItemType Directory -Force (Get-WorkerHome) | Out-Null
    ConvertTo-SecureString $Key -AsPlainText -Force | ConvertFrom-SecureString |
        Set-Content -LiteralPath (Get-WorkerKeyPath) -Encoding ascii
}

# First 12 hex chars of SHA-256: identifies a key without revealing it
function Get-KeyFingerprint([string]$Key) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Key))
    (($bytes | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12)
}

function Get-MaskedKey([string]$Key) {
    if ($Key.Length -le 17) { return '***' }
    return $Key.Substring(0, 13) + '...' + $Key.Substring($Key.Length - 4)
}

# valid | invalid (401/403) | error-<code> | unreachable. Free call: lists one model.
function Test-AnthropicKey([string]$Key) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $base = 'https://api.anthropic.com'
    if ($env:CLAUDE_WORKER_BASE_URL) { $base = $env:CLAUDE_WORKER_BASE_URL.TrimEnd('/') }
    try {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 -Uri "$base/v1/models?limit=1" `
            -Headers @{ 'x-api-key' = $Key; 'anthropic-version' = '2023-06-01' } | Out-Null
        return 'valid'
    }
    catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -eq 401 -or $code -eq 403) { return 'invalid' }
        if ($code) { return "error-$code" }
        return 'unreachable'
    }
}

$script:AnthropicKeyPattern = 'sk-ant-api\d{2}-[A-Za-z0-9_-]{20,}'

# Variables with these prefixes are removed before a worker starts (they would make claude use
# the parent session's login), except CLAUDE_CODE_GIT_BASH_PATH and the names listed in the
# user's CLAUDE_WORKER_KEEP_ENV (comma-separated).
function Test-ShouldDropVariable([string]$Name) {
    if ($Name -notmatch '^(CLAUDE_CODE_|CLAUDE_AGENT_SDK_|ANTHROPIC_)' -and $Name -notin 'CLAUDECODE', 'CLAUDE_PID') { return $false }
    $keep = @('CLAUDE_CODE_GIT_BASH_PATH') + @("$env:CLAUDE_WORKER_KEEP_ENV" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return ($keep -notcontains $Name)
}
