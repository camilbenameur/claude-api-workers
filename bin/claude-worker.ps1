# claude-worker.ps1 - run a headless Claude Code worker (claude -p) billed to your Anthropic
# API key instead of the Claude subscription the calling session runs on. The key exists in
# clear text only inside this process.
#
#   claude-worker.ps1 -PromptFile brief.md [-Model sonnet] [-Cwd dir] [-OutFile out.json] [claude options...]
#   claude-worker.ps1 -Prompt "..."        [...]
#   claude-worker.ps1 -SelfTest            (cheap Haiku call: checks the worker really runs on the key)
#
# The worker has its own Task and Workflow tools: a workflow started inside it bills every
# agent to the key. Unknown options (--output-format json, --permission-mode ...) go to claude.
# No param() block on purpose: PowerShell would bind those options positionally to our own
# parameters, so $args is parsed by hand (same behaviour with -File and with &).
#
# Exit codes: claude's own code, or 2 bad input / key problem, 3 called from inside a worker,
# 127 claude not on PATH.
. "$PSScriptRoot\claude-worker-lib.ps1"

function Fail([int]$Code, [string]$Message) { [Console]::Error.WriteLine("claude-worker: $Message"); exit $Code }

$Prompt = ''; $PromptFile = ''; $Model = ''; $Cwd = (Get-Location).Path; $OutFile = ''; $SelfTest = $false
$ClaudeArgs = @()
for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    if ($a -match '^-(Prompt|PromptFile|Model|Cwd|OutFile)$') {
        if ($i + 1 -ge $args.Count) { Fail 2 "$a needs a value" }
        $i++
        Set-Variable -Name $Matches[1] -Value ([string]$args[$i])
    }
    elseif ($a -eq '-SelfTest') { $SelfTest = $true }
    else { $ClaudeArgs += $a }
}

# Recursion guard: the worker's own agents read the same CLAUDE.md rule
if ($env:CLAUDE_WORKER -eq '1') { Fail 3 'already inside an API worker: use your Task or Workflow tools directly' }

# -Cwd "C:\dir\" makes Windows read \" as an escaped quote that swallows the next options
if ($Cwd -match '"') { Fail 2 "Cwd contains a quote ($Cwd): drop the trailing backslash from the path" }
if (-not (Test-Path -LiteralPath $Cwd -PathType Container)) { Fail 2 "Cwd not found: $Cwd" }

if ($SelfTest) {
    $Prompt = 'Reply with exactly: worker OK'
    if (-not $Model) { $Model = 'haiku' }
}
elseif ($PromptFile) {
    if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) { Fail 2 "PromptFile not found: $PromptFile" }
    $Prompt = Get-Content -LiteralPath $PromptFile -Raw -Encoding UTF8
}
if (-not $Prompt) { Fail 2 'missing -Prompt or -PromptFile' }
if (-not $Model) { $Model = 'sonnet' }
if ($OutFile -and -not [IO.Path]::IsPathRooted($OutFile)) { $OutFile = Join-Path (Get-Location).Path $OutFile }

$claude = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $claude) { Fail 127 'claude not found on PATH (install the Claude Code CLI)' }

# Missing or undecryptable key = hard stop: without it claude would fall back to the subscription
$key = Read-StoredKey
if ($null -eq $key) { Fail 2 'no API key stored: run set-worker-key.ps1' }
if (-not $key.StartsWith('sk-ant-')) { Fail 2 'stored key unreadable or invalid: run set-worker-key.ps1 again' }

# Drop everything the Claude app passes to its child processes (account, session, API URL),
# otherwise the worker would authenticate as the subscription instead of the key.
@(Get-ChildItem Env: | Where-Object { Test-ShouldDropVariable $_.Name }) |
    ForEach-Object { Remove-Item "Env:$($_.Name)" -ErrorAction SilentlyContinue }

$env:ANTHROPIC_API_KEY = $key
$key = $null
$env:CLAUDE_WORKER = '1'
if ($env:CLAUDE_WORKER_BASE_URL) { $env:ANTHROPIC_BASE_URL = $env:CLAUDE_WORKER_BASE_URL }

$utf8 = New-Object Text.UTF8Encoding $false
$guard = 'You are an API worker started by another Claude Code session: you are already billed to the API key. Never call claude-worker; to parallelize, use your Task or Workflow tools directly.'
$base = @('-p', '--model', $Model, '--append-system-prompt', $guard)
$workDir = (Resolve-Path -LiteralPath $Cwd).ProviderPath

# One argument, quoted by the MSVC command-line rules that claude.exe (Node) parses
function ConvertTo-NativeArgument([string]$Value) {
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    return '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

# Runs claude with the prompt on stdin. Output goes straight to our stdout, or byte for byte
# into $OutPath. A real .exe is started directly, so Windows PowerShell 5.1 cannot mangle the
# arguments (inline JSON) or the encoding (non-ASCII prompts); npm .cmd/.ps1 shims go through
# PowerShell with UTF-8 forced.
function Invoke-Claude([string[]]$ArgList, [string]$OutPath) {
    if ($claude.CommandType -eq 'Application' -and $claude.Source -match '\.exe$') {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $claude.Source
        $psi.Arguments = (@($ArgList) | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
        $psi.WorkingDirectory = $workDir
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = [bool]$OutPath
        $p = [Diagnostics.Process]::Start($psi)
        $copy = $null; $file = $null
        try {
            if ($OutPath) {
                $file = [IO.File]::Create($OutPath)
                $copy = $p.StandardOutput.BaseStream.CopyToAsync($file)
            }
            try {
                $bytes = $utf8.GetBytes($Prompt)
                $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
                $p.StandardInput.Close()
            }
            catch [IO.IOException] { }   # claude exited before reading stdin: its exit code still matters
            $p.WaitForExit()
            if ($copy) { $copy.Wait() }
        }
        finally { if ($file) { $file.Close() } }
        return $p.ExitCode
    }
    $global:OutputEncoding = $utf8
    [Console]::OutputEncoding = $utf8
    Push-Location -LiteralPath $workDir
    try {
        if ($OutPath) {
            $out = $Prompt | & $claude.Source @ArgList
            [IO.File]::WriteAllLines($OutPath, [string[]]@($out), $utf8)
        }
        else { $Prompt | & $claude.Source @ArgList | Out-Host }
        if ($null -eq $LASTEXITCODE) { return 1 } else { return $LASTEXITCODE }
    }
    finally { Pop-Location }
}

try {
    if ($SelfTest) {
        $tmpOut = [IO.Path]::GetTempFileName()
        $null = Invoke-Claude ($base + @('--output-format', 'stream-json', '--verbose', '--max-turns', '1')) $tmpOut
        $source = '?'; $result = '?'; $cost = '?'
        foreach ($line in [IO.File]::ReadAllLines($tmpOut, $utf8)) {
            try { $j = $line | ConvertFrom-Json } catch { continue }
            if ($j.type -eq 'system' -and $j.subtype -eq 'init') { $source = $j.apiKeySource }
            if ($j.type -eq 'result') { $result = $j.result; $cost = $j.total_cost_usd }
        }
        Remove-Item -LiteralPath $tmpOut -ErrorAction SilentlyContinue
        Write-Output "apiKeySource=$source result=$result cost_usd=$cost"
        $code = 1
        if ($source -eq 'ANTHROPIC_API_KEY' -and "$result" -match 'worker OK') { $code = 0 }
    }
    else {
        $code = Invoke-Claude ($base + $ClaudeArgs) $OutFile
    }
}
finally {
    Remove-Item Env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
}
exit $code
