# claude-worker.ps1 - run a headless Claude Code worker (claude -p) billed to your Anthropic
# API key instead of the Claude subscription the calling session runs on. The key exists in
# clear text only inside this process.
#
#   claude-worker.ps1 -PromptFile brief.md [-Name name] [-Model sonnet] [-Cwd dir] [-OutFile out.json] [claude options...]
#   claude-worker.ps1 -Prompt "..."        [...]
#   claude-worker.ps1 -SelfTest            (cheap Haiku call: checks the worker really runs on the key)
#   add -Fast to ask for fast mode (Opus). It is used when the key's organization has it,
#   and the worker runs at standard speed otherwise. -SelfTest -Model opus -Fast shows which.
#
# Crash recovery: every run is recorded (its id is printed on stderr at start). When a worker
# fails (credit, key, API or network error, killed...), the launcher says why, and:
#   claude-worker.ps1 -Runs                       lists the runs and their state
#   claude-worker.ps1 -Recover <id|name|last>     report: brief, progress, files changed, last messages, git
#   claude-worker.ps1 -ResumeRun <id|name|last>   continues the same conversation (claude --resume),
#                                                 same model, folder, options and output file
#
# The worker has its own Task and Workflow tools: a workflow started inside it bills every
# agent to the key. Unknown options (--output-format json, --permission-mode ...) go to claude.
# No param() block on purpose: PowerShell would bind those options positionally to our own
# parameters, so $args is parsed by hand (same behaviour with -File and with &).
#
# Exit codes: claude's own code (1 when claude exits 0 but reports an error), or 2 bad input /
# key problem, 3 called from inside a worker, 127 claude not on PATH.

# Progress records (module auto-loading) would reach a redirected stderr as CLIXML, which a
# calling PowerShell then fails to parse, losing our own messages
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\claude-worker-lib.ps1"
. "$PSScriptRoot\claude-worker-runs.ps1"

function Fail([int]$Code, [string]$Message) { [Console]::Error.WriteLine("claude-worker: $Message"); exit $Code }

$utf8 = New-Object Text.UTF8Encoding $false

# Raw UTF-8 on stdout: Write-Output would go through the console code page
function Write-Utf8Out([string]$Text) {
    $bytes = $utf8.GetBytes($Text)
    $out = [Console]::OpenStandardOutput()
    $out.Write($bytes, 0, $bytes.Length); $out.Flush()
}

$Prompt = ''; $PromptFile = ''; $Model = ''; $Cwd = ''; $OutFile = ''; $Name = ''; $Recover = ''; $ResumeRun = ''
$SelfTest = $false; $Fast = $false; $Runs = $false; $Force = $false
$ClaudeArgs = @()
for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    if ($a -match '^-(Prompt|PromptFile|Model|Cwd|OutFile|Name|Recover|ResumeRun)$') {
        if ($i + 1 -ge $args.Count) { Fail 2 "$a needs a value" }
        $i++
        Set-Variable -Name $Matches[1] -Value ([string]$args[$i])
    }
    elseif ($a -eq '-SelfTest') { $SelfTest = $true }
    elseif ($a -eq '-Fast') { $Fast = $true }
    elseif ($a -eq '-Runs') { $Runs = $true }
    elseif ($a -eq '-Force') { $Force = $true }
    else { $ClaudeArgs += $a }
}

# Recursion guard: the worker's own agents read the same CLAUDE.md rule
if ($env:CLAUDE_WORKER -eq '1') { Fail 3 'already inside an API worker: use your Task or Workflow tools directly' }

if ($Runs) {
    $all = @(Get-RunRecords)
    if (-not $all.Count) { Write-Output 'No worker runs recorded.'; exit 0 }
    $lines = @(('{0,-40} {1,-22} {2,-25} {3}' -f 'ID', 'STATE', 'STARTED', 'FOLDER'))
    $lines += @($all | Select-Object -Last 30 | ForEach-Object { Format-RunLine $_ })
    if ($all.Count -gt 30) { $lines += "($($all.Count - 30) older runs in $(Get-RunsRoot))" }
    Write-Utf8Out (($lines -join "`n") + "`n")
    exit 0
}

if ($Recover) {
    $run = Find-RunRecord $Recover
    if (-not $run) { Fail 2 "no run matches '$Recover' (see -Runs)" }
    $report = Get-RunReport $run
    [IO.File]::WriteAllText((Join-Path $run.dir 'report.md'), $report, $utf8)
    if ($OutFile) { [IO.File]::WriteAllText($OutFile, $report, $utf8) }
    Write-Utf8Out $report
    exit 0
}

$run = $null
$resumeTranscript = $false
if ($ResumeRun) {
    $run = Find-RunRecord $ResumeRun
    if (-not $run) { Fail 2 "no run matches '$ResumeRun' (see -Runs)" }
    $state = Get-RunState $run
    if ($state -eq 'running') { Fail 2 "run $($run.id) is still running (launcher PID $($run.launcher_pid))" }
    if ($state -eq 'orphaned' -and -not $Force) { Fail 2 "claude is still running for run $($run.id) (PID $($run.claude_pid)): wait for it or stop it, or add -Force" }
    if (-not $run.session_id) { Fail 2 "run $($run.id) has no session id: it cannot be resumed" }
    if ($Cwd -and $Cwd -ne $run.cwd) { Fail 2 "a resumed run keeps its folder ($($run.cwd)): drop -Cwd" }
    $Cwd = $run.cwd
    if (-not $Model) { $Model = $run.model }
    if ($run.fast -eq '1') { $Fast = $true }
    if (-not $OutFile) { $OutFile = $run.out_file }
    $resumeTranscript = [bool](Find-RunTranscript $run)
    if (-not $Prompt -and -not $PromptFile) {
        # No conversation was saved (claude failed at start): replay the original brief
        if ($resumeTranscript) { $Prompt = Get-ResumePrompt $run }
        else { $Prompt = [IO.File]::ReadAllText((Join-Path $run.dir 'prompt.md'), $utf8) }
    }
}

if (-not $Cwd) { $Cwd = (Get-Location).Path }
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
# claude -p stops background tasks 10 minutes after its last turn, which would kill a workflow
# the worker started. 0 = wait for them. A value kept through CLAUDE_WORKER_KEEP_ENV wins.
if (-not $env:CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS) { $env:CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS = '0' }

$guard = 'You are an API worker started by another Claude Code session: you are already billed to the API key. Never call claude-worker; to parallelize, use your Task or Workflow tools directly.'
$base = @('-p', '--model', $Model, '--append-system-prompt', $guard)
$workDir = (Resolve-Path -LiteralPath $Cwd).ProviderPath

# claude -p only uses fast mode when the --settings file opts in. The Anthropic API still
# decides per organization: without access, the worker simply runs at standard speed.
$fastFile = $null
if ($Fast) {
    $fastFile = [IO.Path]::Combine([IO.Path]::GetTempPath(), "claude-worker-fast-$PID.json")
    [IO.File]::WriteAllText($fastFile, '{"fastMode": true}', $utf8)
    $base += @('--settings', $fastFile)
}

# One argument, quoted by the MSVC command-line rules that claude.exe (Node) parses
function ConvertTo-NativeArgument([string]$Value) {
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    return '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

# Runs claude with the prompt on stdin. Output goes straight to our stdout, or byte for byte
# into $OutPath; stderr goes to $ErrPath when given. A real .exe is started directly, so Windows
# PowerShell 5.1 cannot mangle the arguments (inline JSON) or the encoding (non-ASCII prompts);
# npm .cmd/.ps1 shims go through PowerShell with UTF-8 forced (their stderr is not captured).
function Invoke-Claude([string[]]$ArgList, [string]$OutPath, [string]$ErrPath, $Record) {
    if ($claude.CommandType -eq 'Application' -and $claude.Source -match '\.exe$') {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $claude.Source
        $psi.Arguments = (@($ArgList) | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
        $psi.WorkingDirectory = $workDir
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = [bool]$OutPath
        $psi.RedirectStandardError = [bool]$ErrPath
        # .NET builds the stdin writer with Console.InputEncoding and writes its preamble at once:
        # a UTF-8 console code page would put a BOM in front of the prompt
        try { if ([Console]::InputEncoding.CodePage -eq 65001) { [Console]::InputEncoding = $utf8 } } catch {}
        $p = [Diagnostics.Process]::Start($psi)
        if ($Record) { $Record.claude_pid = "$($p.Id)"; Save-RunRecord $Record }
        $copy = $null; $file = $null; $errCopy = $null; $errFile = $null
        try {
            if ($OutPath) {
                $file = [IO.File]::Create($OutPath)
                $copy = $p.StandardOutput.BaseStream.CopyToAsync($file)
            }
            if ($ErrPath) {
                $errFile = [IO.File]::Open($ErrPath, 'Append', 'Write', 'ReadWrite')
                $errCopy = $p.StandardError.BaseStream.CopyToAsync($errFile)
            }
            try {
                $bytes = $utf8.GetBytes($Prompt)
                $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
                $p.StandardInput.Close()
            }
            catch [IO.IOException] { }   # claude exited before reading stdin: its exit code still matters
            $p.WaitForExit()
            if ($copy) { $copy.Wait() }
            if ($errCopy) { $errCopy.Wait() }
        }
        finally {
            if ($file) { $file.Close() }
            if ($errFile) { $errFile.Close() }
        }
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

# Index of the first of $Names in $List, or -1
function Find-Option([string[]]$List, [string[]]$Names) {
    for ($k = 0; $k -lt $List.Count; $k++) { if ($Names -contains $List[$k]) { return $k } }
    return -1
}

$code = 1
try {
    if ($SelfTest) {
        $tmpOut = [IO.Path]::GetTempFileName()
        $null = Invoke-Claude ($base + @('--output-format', 'stream-json', '--verbose', '--max-turns', '1')) $tmpOut '' $null
        $source = '?'; $result = '?'; $cost = '?'; $fastState = '?'
        foreach ($line in [IO.File]::ReadAllLines($tmpOut, $utf8)) {
            try { $j = $line | ConvertFrom-Json } catch { continue }
            if ($j.type -eq 'system' -and $j.subtype -eq 'init') {
                $source = $j.apiKeySource
                $fastState = "$($j.fast_mode_state)"
                if ($j.fast_mode_disabled_reason) { $fastState += " ($($j.fast_mode_disabled_reason))" }
            }
            if ($j.type -eq 'result') { $result = $j.result; $cost = $j.total_cost_usd; $speed = $j.usage.speed }
        }
        Remove-Item -LiteralPath $tmpOut -ErrorAction SilentlyContinue
        Write-Output "apiKeySource=$source result=$result cost_usd=$cost model=$Model fast_mode=$fastState speed=$speed"
        if ($source -eq 'ANTHROPIC_API_KEY' -and "$result" -match 'worker OK') { $code = 0 }
    }
    else {
        if ($run) {
            # Resume: same session, the options of the first launch (minus its session flag), then ours
            $stored = New-Object Collections.Generic.List[string]
            $sa = @($run.args)
            for ($k = 0; $k -lt $sa.Count; $k++) {
                if ($sa[$k] -eq '--session-id') { $k++; continue }
                $stored.Add($sa[$k])
            }
            $sessionArgs = if ($resumeTranscript) { @('--resume', $run.session_id) } else { @('--session-id', $run.session_id) }
            $claudeLine = @($stored.ToArray()) + @($ClaudeArgs) + $sessionArgs
            $run.attempts = "$([int]$run.attempts + 1)"
            [IO.File]::WriteAllText((Join-Path $run.dir "resume-$($run.attempts).md"), $Prompt, $utf8)
            $run.model = $Model; $run.fast = $(if ($Fast) { '1' } else { '0' }); $run.out_file = $OutFile
            $run.status = 'running'; $run.reason = ''; $run.detail = ''; $run.exit_code = ''; $run.ended = ''
        }
        else {
            # A session id chosen here lets -ResumeRun find the conversation later
            $sessionId = ''
            $at = Find-Option $ClaudeArgs @('--session-id')
            if ($at -ge 0 -and $at + 1 -lt $ClaudeArgs.Count) { $sessionId = $ClaudeArgs[$at + 1] }
            $sessionArgs = @()
            if (-not $sessionId -and (Find-Option $ClaudeArgs @('--resume', '-r', '--continue', '-c', '--fork-session')) -lt 0) {
                $sessionId = [guid]::NewGuid().ToString()
                $sessionArgs = @('--session-id', $sessionId)
            }
            $run = New-RunRecord $Name $sessionId
            $run.cwd = $workDir; $run.model = $Model; $run.fast = $(if ($Fast) { '1' } else { '0' }); $run.out_file = $OutFile
            $run.args = $ClaudeArgs
            $git = Get-GitInfo $workDir
            $run.git_root = $git.root; $run.git_head = $git.head
            if ($git.root) { [IO.File]::WriteAllText((Join-Path $run.dir 'git-start.txt'), ((& git -C $git.root status --porcelain 2>$null) -join "`n"), $utf8) }
            [IO.File]::WriteAllText((Join-Path $run.dir 'prompt.md'), $Prompt, $utf8)
            $claudeLine = @($ClaudeArgs) + $sessionArgs
        }
        $run.launcher_pid = "$PID"; $run.claude_pid = ''
        $run.last_start = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        Save-RunRecord $run
        [Console]::Error.WriteLine("claude-worker: run $($run.id) (session $($run.session_id), attempt $($run.attempts))")

        $errLog = Join-Path $run.dir 'stderr.log'
        $code = Invoke-Claude ($base + $claudeLine) $OutFile $errLog $run
        if (Test-Path -LiteralPath $errLog) {
            $bytes = [IO.File]::ReadAllBytes($errLog)
            $errOut = [Console]::OpenStandardError(); $errOut.Write($bytes, 0, $bytes.Length); $errOut.Flush()
        }
        $outcome = Complete-RunRecord $run $code $false
        if ($outcome.failed) {
            [Console]::Error.WriteLine("claude-worker: run $($run.id) failed ($($outcome.reason)): $($outcome.detail)")
            [Console]::Error.WriteLine("claude-worker: what it did so far: -Recover $($run.id); continue it with its whole context: -ResumeRun $($run.id)")
            if ($code -eq 0) { $code = 1 }
        }
    }
}
finally {
    Remove-Item Env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
    if ($fastFile) { Remove-Item -LiteralPath $fastFile -ErrorAction SilentlyContinue }
    if ($run -and $run.status -eq 'running' -and $run.launcher_pid -eq "$PID") {
        # The launcher itself failed (or was stopped by Ctrl+C) before recording an end
        $run.status = 'failed'; $run.reason = 'interrupted'; $run.detail = 'the launcher stopped before claude finished'
        $run.ended = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        try { Save-RunRecord $run } catch {}
    }
}
exit $code
