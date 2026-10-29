# set-worker-key.ps1 - store the Anthropic API key that claude-worker.ps1 uses, encrypted with
# DPAPI (only your Windows account can decrypt it). Meant to be run BY THE USER in a terminal:
# agents only hand out the command.
#
#   set-worker-key.ps1                    hidden prompt: paste the key, press Enter
#   set-worker-key.ps1 -From <fingerprint> use a key found by find-api-keys.ps1 (fingerprint from its list)
#   set-worker-key.ps1 -Status            show the stored key, masked, and whether it still works
#   set-worker-key.ps1 -Remove            delete the stored key
# Add -NoCheck to skip the online check, -Force to store a key the API rejects.
param(
    [string]$From,
    [switch]$Status,
    [switch]$Remove,
    [switch]$NoCheck,
    [switch]$Force
)
. "$PSScriptRoot\claude-worker-lib.ps1"
$file = Get-WorkerKeyPath

if ($Remove) {
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force; Write-Output 'Stored key removed.' }
    else { Write-Output 'No key stored.' }
    exit 0
}

if ($Status) {
    $key = Read-StoredKey
    if ($null -eq $key) { Write-Output "No key stored ($file)."; exit 1 }
    if (-not $key) { Write-Output "Key file unreadable (another Windows account or machine?): $file"; exit 2 }
    $state = if ($NoCheck) { 'unchecked' } else { Test-AnthropicKey $key }
    Write-Output ("Stored key: {0} [{1}] - {2}" -f (Get-MaskedKey $key), (Get-KeyFingerprint $key), $state)
    if ($state -eq 'valid' -or $state -eq 'unchecked') { exit 0 } else { exit 1 }
}

if ($From) {
    $prefix = $From.Trim().ToLowerInvariant()
    if ($prefix.Length -lt 8) { Write-Error 'Give at least 8 characters of the fingerprint.'; exit 2 }
    Write-Output 'Looking for the key again (same scan as find-api-keys.ps1)...'
    $matching = @(& "$PSScriptRoot\find-api-keys.ps1" -PassThruSecret | Where-Object { $_.fingerprint.StartsWith($prefix) })
    if ($matching.Count -ne 1) { Write-Error "No single key matches fingerprint '$From' ($($matching.Count) found). Run find-api-keys.ps1 again."; exit 2 }
    $key = $matching[0].key
    Write-Output ("Using {0} found in: {1}" -f $matching[0].masked, ($matching[0].sources -join '; '))
}
else {
    $secure = Read-Host 'Paste your Anthropic API key (nothing is shown), then Enter' -AsSecureString
    $key = [System.Net.NetworkCredential]::new('', $secure).Password
}

$key = "$key".Trim()
if (-not $key) { Write-Output 'Nothing entered, cancelled.'; exit 2 }
if ($key -notmatch '^sk-ant-api\d{2}-' -and -not $Force) {
    Write-Error 'This is not an Anthropic Console API key (sk-ant-api...). Use -Force to store it anyway.'
    exit 2
}
if (-not $NoCheck) {
    $state = Test-AnthropicKey $key
    if ($state -eq 'invalid' -and -not $Force) { Write-Error 'The Anthropic API rejects this key (401/403): revoked or expired? Nothing stored.'; exit 2 }
    if ($state -ne 'valid') { Write-Warning "Could not confirm the key ($state); storing it anyway." }
}

Save-StoredKey $key
Write-Output ("Key stored, encrypted for this Windows account: {0} [{1}] in {2}" -f (Get-MaskedKey $key), (Get-KeyFingerprint $key), $file)
Write-Output 'Workers started from now on use it. Test: claude-worker.ps1 -SelfTest'
