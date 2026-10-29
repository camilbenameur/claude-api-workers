# install.ps1 - install claude-api-workers for Claude Code on Windows.
#   install.ps1 [-Mode always|on-request] [-Prefix dir]   install or update (idempotent)
#   install.ps1 -Uninstall [-Prefix dir]                  remove the scripts and the CLAUDE.md block
# Copies the scripts (and this installer, for a later -Uninstall) to ~/.claude/claude-worker and
# writes a marked block into ~/.claude/CLAUDE.md. The file as it was before the first install is
# kept as CLAUDE.md.bak-claude-api-workers. Never touches the stored API key.
param(
    [ValidateSet('always', 'on-request')][string]$Mode = 'always',
    [string]$Prefix,
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$claudeDir = Join-Path $env:USERPROFILE '.claude'
if (-not $Prefix) { $Prefix = Join-Path $claudeDir 'claude-worker' }
$claudeMd = Join-Path $claudeDir 'CLAUDE.md'
$backup = "$claudeMd.bak-claude-api-workers"
$begin = '<!-- claude-api-workers:begin -->'
$end = '<!-- claude-api-workers:end -->'
$repoUrl = 'https://github.com/camilbenameur/claude-api-workers'
$utf8 = New-Object Text.UTF8Encoding $false
$scripts = 'claude-worker.ps1', 'set-worker-key.ps1', 'find-api-keys.ps1', 'claude-worker-lib.ps1'
$extras = 'install.ps1', 'rules\rule.md', 'rules\mode-always.md', 'rules\mode-on-request.md'

# A begin marker without its end (or the reverse) means a hand-edited file: refuse to guess
if (Test-Path -LiteralPath $claudeMd) {
    $current = [IO.File]::ReadAllText($claudeMd)
    $nb = ([regex]::Matches($current, '(?m)^' + [regex]::Escape($begin) + '\r?$')).Count
    $ne = ([regex]::Matches($current, '(?m)^' + [regex]::Escape($end) + '\r?$')).Count
    if ($nb -ne $ne -or $nb -gt 1) {
        Write-Error "$claudeMd has unbalanced claude-api-workers markers ($nb begin, $ne end): fix them by hand, then rerun."
    }
}

# CLAUDE.md without our block (and without the blank lines it leaves behind)
function Get-OtherContent {
    if (-not (Test-Path -LiteralPath $claudeMd)) { return '' }
    $text = [IO.File]::ReadAllText($claudeMd)
    $pattern = '(?s)\r?\n*' + [regex]::Escape($begin) + '.*?' + [regex]::Escape($end) + '\r?\n?'
    return ([regex]::Replace($text, $pattern, "`n")).TrimEnd()
}

# WriteAllText follows a symbolic link, so a CLAUDE.md linked from a dotfiles repo stays linked
function Save-ClaudeMd([string]$Text) {
    New-Item -ItemType Directory -Force $claudeDir | Out-Null
    if ((Test-Path -LiteralPath $claudeMd) -and -not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $claudeMd $backup }
    [IO.File]::WriteAllText($claudeMd, $Text, $utf8)
}

if ($Uninstall) {
    if (Test-Path -LiteralPath $claudeMd) {
        $rest = Get-OtherContent
        if ($rest) { Save-ClaudeMd ($rest + "`n") } else { Save-ClaudeMd '' }
    }
    foreach ($f in $scripts) { Remove-Item -LiteralPath (Join-Path $Prefix "bin\$f") -Force -ErrorAction SilentlyContinue }
    foreach ($f in $extras) { Remove-Item -LiteralPath (Join-Path $Prefix $f) -Force -ErrorAction SilentlyContinue }
    foreach ($d in (Join-Path $Prefix 'bin'), (Join-Path $Prefix 'rules'), $Prefix) {
        if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force)) { Remove-Item -LiteralPath $d -Force }
    }
    Write-Output "Removed the claude-api-workers scripts from $Prefix and its block from $claudeMd."
    Write-Output "The stored API key is kept. To delete it too, run set-worker-key.ps1 -Remove before uninstalling, or delete $env:LOCALAPPDATA\claude-worker\key.dat."
    exit 0
}

# 1. Scripts, plus this installer and the rules so -Uninstall works without the clone
$bin = Join-Path $Prefix 'bin'
New-Item -ItemType Directory -Force $bin, (Join-Path $Prefix 'rules') | Out-Null
if ((Resolve-Path -LiteralPath $Prefix).ProviderPath.TrimEnd('\') -ne $src.TrimEnd('\')) {
    foreach ($f in $scripts) { Copy-Item -LiteralPath (Join-Path $src "bin\$f") -Destination $bin -Force }
    foreach ($f in $extras) { Copy-Item -LiteralPath (Join-Path $src $f) -Destination (Join-Path $Prefix $f) -Force }
}

# 2. Rule block
$ps = 'powershell -NoProfile -ExecutionPolicy Bypass -File'
$worker = "$ps `"$bin\claude-worker.ps1`""
$setKey = "$ps `"$bin\set-worker-key.ps1`""
$notes = @(
    '   - Write the output with `-OutFile`, never with a `>` redirect: Windows PowerShell 5.1 mangles non-ASCII characters there.'
    '   - Never end a `-Cwd` path with a backslash (`C:\proj`, not `C:\proj\`): Windows would read `\"` as an escaped quote.'
    '   - Put JSON options in a file rather than inline: a calling PowerShell may strip their quotes.'
    '   - A "claude.ai connectors are disabled" line on stderr is expected.'
) -join "`n"
$rule = [IO.File]::ReadAllText((Join-Path $src 'rules\rule.md'))
$values = [ordered]@{
    '{{MODE_RULE}}'      = ([IO.File]::ReadAllText((Join-Path $src "rules\mode-$Mode.md"))).Trim()
    '{{DATE}}'           = (Get-Date -Format 'yyyy-MM-dd')
    '{{REPO_URL}}'       = $repoUrl
    '{{SHELL_TOOL}}'     = 'PowerShell (or Bash)'
    '{{RUN_EXAMPLE}}'    = "$worker -PromptFile `"<brief.md>`" -Model sonnet -Cwd `"<project dir>`" -OutFile `"<scratchpad>\out-<name>.json`" --permission-mode acceptEdits --output-format json"
    '{{PLATFORM_NOTES}}' = $notes
    '{{SETKEY_CMD}}'     = $setKey
    '{{STATUS_CMD}}'     = "$setKey -Status"
}
foreach ($k in $values.Keys) { $rule = $rule.Replace($k, $values[$k]) }
$block = "$begin`n$($rule.Trim())`n$end"

$rest = Get-OtherContent
if ($rest -match 'claude-worker') {
    Write-Warning "$claudeMd already mentions claude-worker outside the claude-api-workers block: check for a duplicate rule."
}
if ($rest) { Save-ClaudeMd "$rest`n`n$block`n" } else { Save-ClaudeMd "$block`n" }

Write-Output "Installed claude-api-workers ($Mode mode):"
Write-Output "  scripts : $bin"
Write-Output "  rule    : block in $claudeMd (original kept as $backup)"
Write-Output ''
Write-Output 'Next steps:'
Write-Output "  find keys already on this machine (masked): $ps `"$bin\find-api-keys.ps1`" -Check"
Write-Output "  store a key (the user runs it)            : $setKey   (or add -From <fingerprint>)"
Write-Output "  check the worker                           : $worker -SelfTest"
Write-Output "  uninstall                                  : $ps `"$Prefix\install.ps1`" -Uninstall"
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Warning 'The claude CLI is not on PATH: workers need it (https://docs.claude.com/en/docs/claude-code/setup).'
}
