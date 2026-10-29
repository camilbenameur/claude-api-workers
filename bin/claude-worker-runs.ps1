# Run records and crash recovery for claude-worker.ps1 (dot-sourced after claude-worker-lib.ps1).
# Kept pure ASCII, like claude-worker-lib.ps1.
#
# Every worker run gets a folder <worker home>\runs\<id>:
#   run.info    key=value lines (values percent-encoded for %, CR and LF; one arg= line per claude option)
#   prompt.md   the brief; resume-<n>.md holds the prompt of each later resume
#   stderr.log  what claude wrote on stderr
#   git-start.txt  `git status --porcelain` when the run started (git folders only)
#   report.md   the last recovery report (-Recover)
# The worker's conversation itself is Claude Code's transcript, <config>\projects\<dir>\<session>.jsonl,
# with its sub-agents and workflows under <config>\projects\<dir>\<session>\.

$script:RunsUtf8 = New-Object Text.UTF8Encoding $false
$script:EditTools = 'Edit', 'Write', 'MultiEdit', 'NotebookEdit'

function Get-RunsRoot { Join-Path (Get-WorkerHome) 'runs' }

function Get-ClaudeConfigDir {
    if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
    return (Join-Path $env:USERPROFILE '.claude')
}

function ConvertTo-InfoValue([string]$Value) { $Value.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A') }
function ConvertFrom-InfoValue([string]$Value) { $Value.Replace('%0A', "`n").Replace('%0D', "`r").Replace('%25', '%') }

$script:RunFields = 'id', 'name', 'session_id', 'cwd', 'model', 'fast', 'out_file', 'status', 'reason', 'detail',
    'exit_code', 'attempts', 'started', 'last_start', 'ended', 'launcher_pid', 'claude_pid', 'git_root', 'git_head'

function New-RunRecord([string]$Name, [string]$SessionId) {
    $root = Get-RunsRoot
    New-Item -ItemType Directory -Force $root | Out-Null
    $label = if ($Name) { ($Name -replace '[^A-Za-z0-9._-]', '-') } elseif ($SessionId) { $SessionId.Substring(0, 8) } else { 'run' }
    if ($label.Length -gt 40) { $label = $label.Substring(0, 40) }
    $id = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + $label
    while (Test-Path -LiteralPath (Join-Path $root $id)) { $id += '-' + [guid]::NewGuid().ToString().Substring(0, 4) }
    $run = [ordered]@{}
    foreach ($f in $script:RunFields) { $run[$f] = '' }
    $run.id = $id; $run.name = $Name; $run.session_id = $SessionId; $run.attempts = '1'; $run.status = 'running'
    $run.started = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'); $run.last_start = $run.started
    $run.args = @()
    $run.dir = Join-Path $root $id
    New-Item -ItemType Directory -Force $run.dir | Out-Null
    return $run
}

function Save-RunRecord($Run) {
    $lines = New-Object Collections.Generic.List[string]
    foreach ($f in $script:RunFields) { $lines.Add("$f=" + (ConvertTo-InfoValue ([string]$Run[$f]))) }
    foreach ($a in @($Run.args)) { $lines.Add('arg=' + (ConvertTo-InfoValue ([string]$a))) }
    $file = Join-Path $Run.dir 'run.info'
    [IO.File]::WriteAllLines("$file.tmp", $lines.ToArray(), $script:RunsUtf8)
    Move-Item -LiteralPath "$file.tmp" -Destination $file -Force
}

function Read-RunRecord([string]$Dir) {
    $file = Join-Path $Dir 'run.info'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    $run = [ordered]@{}
    foreach ($f in $script:RunFields) { $run[$f] = '' }
    $args2 = New-Object Collections.Generic.List[string]
    foreach ($line in [IO.File]::ReadAllLines($file, $script:RunsUtf8)) {
        $i = $line.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $line.Substring(0, $i); $v = ConvertFrom-InfoValue $line.Substring($i + 1)
        if ($k -eq 'arg') { $args2.Add($v) } else { $run[$k] = $v }
    }
    $run.args = $args2.ToArray()
    $run.dir = $Dir
    return $run
}

# All runs, oldest first (ids start with a timestamp)
function Get-RunRecords {
    $root = Get-RunsRoot
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    @(Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name | ForEach-Object { Read-RunRecord $_.FullName } | Where-Object { $_ })
}

# A run id, a -Name (latest run with it), a unique prefix of an id or session id, or "last"
function Find-RunRecord([string]$Ref) {
    $runs = @(Get-RunRecords)
    if (-not $runs.Count -or -not $Ref) { return $null }
    if ($Ref -eq 'last') { return $runs[-1] }
    $hit = @($runs | Where-Object { $_.id -eq $Ref })
    if ($hit.Count) { return $hit[-1] }
    $hit = @($runs | Where-Object { $_.name -eq $Ref })
    if ($hit.Count) { return $hit[-1] }
    if ($Ref.Length -ge 6) {
        $hit = @($runs | Where-Object { $_.id.StartsWith($Ref) -or $_.session_id.StartsWith($Ref) })
        if ($hit.Count -eq 1) { return $hit[0] }
    }
    return $null
}

function Test-RunProcess([string]$ProcessId, [string]$Since) {
    if ($ProcessId -notmatch '^\d+$') { return $false }
    $p = Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    # A recycled PID belongs to a process started after the run
    try { if ($Since -and $p.StartTime -gt ([datetime]$Since).AddSeconds(5)) { return $false } } catch {}
    return $true
}

# running | orphaned (launcher gone, claude still running) | interrupted | succeeded | failed
function Get-RunState($Run) {
    if ($Run.status -ne 'running') { return $Run.status }
    if (Test-RunProcess $Run.launcher_pid $Run.last_start) { return 'running' }
    if (Test-RunProcess $Run.claude_pid $Run.last_start) { return 'orphaned' }
    return 'interrupted'
}

function Find-RunTranscript($Run) {
    if (-not $Run.session_id) { return $null }
    $projects = Join-Path (Get-ClaudeConfigDir) 'projects'
    if (-not (Test-Path -LiteralPath $projects)) { return $null }
    $hit = Get-ChildItem -LiteralPath $projects -Directory | ForEach-Object {
        $f = Join-Path $_.FullName "$($Run.session_id).jsonl"
        if (Test-Path -LiteralPath $f -PathType Leaf) { $f }
    } | Select-Object -First 1
    return $hit
}

function Get-GitInfo([string]$Dir) {
    $info = @{ root = ''; head = '' }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $info }
    $root = & git -C $Dir rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $root) { return $info }
    $info.root = "$root".Trim()
    $head = & git -C $Dir rev-parse --verify -q HEAD 2>$null
    if ($LASTEXITCODE -eq 0) { $info.head = "$head".Trim() }
    return $info
}

# Why a run failed, from what claude left behind: the -OutFile JSON (is_error, terminal_reason,
# api_error_status, subtype), the transcript's last assistant message (isApiErrorMessage), stderr.
# Returns @{ failed; reason; detail }.
function Get-RunOutcome($Run, [int]$ExitCode, [bool]$Killed) {
    $facts = New-Object Collections.Generic.List[string]
    $detail = ''
    $isError = $false
    if ($Run.out_file -and (Test-Path -LiteralPath $Run.out_file -PathType Leaf)) {
        $resultLine = $null
        foreach ($l in [IO.File]::ReadLines($Run.out_file, $script:RunsUtf8)) {
            if ($l.TrimStart().StartsWith('{') -and $l.Contains('"type":"result"')) { $resultLine = $l }
        }
        if ($resultLine) {
            try {
                $j = $resultLine | ConvertFrom-Json
                if ($j.is_error) { $isError = $true }
                $facts.Add("subtype=$($j.subtype) terminal_reason=$($j.terminal_reason) api_error_status=$($j.api_error_status)")
                if ($j.is_error -and $j.result) { $detail = [string]$j.result }
                if (-not $Run.session_id -and $j.session_id) { $Run.session_id = [string]$j.session_id }
            }
            catch {}
        }
    }
    $transcript = Find-RunTranscript $Run
    if ($transcript) {
        $last = $null
        foreach ($l in [IO.File]::ReadLines($transcript, $script:RunsUtf8)) { if ($l.Contains('"type":"assistant"')) { $last = $l } }
        if ($last -and $last.Contains('"isApiErrorMessage":true')) {
            $isError = $true
            try {
                $j = $last | ConvertFrom-Json
                $facts.Add("error=$($j.error) status=$($j.apiErrorStatus)")
                $text = @($j.message.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ' '
                if ($text) { $facts.Add($text); if (-not $detail) { $detail = $text } }
            }
            catch {}
        }
    }
    $errLog = Join-Path $Run.dir 'stderr.log'
    if (Test-Path -LiteralPath $errLog -PathType Leaf) {
        $tail = @([IO.File]::ReadAllLines($errLog, $script:RunsUtf8) | Where-Object { $_.Trim() -and $_ -notmatch 'connectors are disabled' } | Select-Object -Last 20)
        if ($tail.Count) { $facts.Add(($tail -join ' ')); if (-not $detail) { $detail = $tail[-1] } }
    }
    $all = ($facts -join ' ')
    $bgStopped = $all -match 'Background tasks still running'
    if ($ExitCode -eq 0 -and -not $isError -and -not $bgStopped -and -not $Killed) {
        return @{ failed = $false; reason = ''; detail = '' }
    }
    $reason = Get-FailureReason $all $ExitCode $Killed
    if (-not $detail) { $detail = "claude exited with code $ExitCode" }
    $detail = ($detail -replace '\s+', ' ').Trim()
    if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 297) + '...' }
    return @{ failed = $true; reason = $reason; detail = $detail }
}

function Get-FailureReason([string]$Text, [int]$ExitCode, [bool]$Killed) {
    if ($Killed) { return 'killed' }
    $rules = [ordered]@{
        'max_turns'  = 'error_max_turns'
        'budget'     = 'error_max_budget|max-budget'
        'credit'     = 'billing_error|credit balance|insufficient_quota|spend limit|status=402'
        'auth'       = 'authentication|invalid api key|invalid x-api-key|permission_error|status=40[13]([^0-9]|$)'
        'rate_limit' = 'rate_limit|status=429'
        'overloaded' = 'overloaded|status=529'
        'network'    = 'ECONNREFUSED|ECONNRESET|ETIMEDOUT|ENOTFOUND|EAI_AGAIN|connection (refused|error|reset)|socket hang up|fetch failed|network'
        'server'     = 'server_error|status=5[0-9][0-9]|internal server error'
        'request'    = 'invalid_request|status=4[0-9][0-9]'
        'bg_timeout' = 'Background tasks still running'
    }
    # "status=" also matches the api_error_status=NNN of the JSON result
    foreach ($k in $rules.Keys) { if ($Text -match $rules[$k]) { return $k } }
    if ($ExitCode -in 130, 137, 143) { return 'killed' }
    return 'unknown'
}

# Stops the run record: status, reason, exit code, end time
function Complete-RunRecord($Run, [int]$ExitCode, [bool]$Killed) {
    $o = Get-RunOutcome $Run $ExitCode $Killed
    $Run.status = if ($o.failed) { 'failed' } else { 'succeeded' }
    $Run.reason = $o.reason; $Run.detail = $o.detail
    $Run.exit_code = "$ExitCode"
    $Run.ended = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    Save-RunRecord $Run
    return $o
}

function Format-RunLine($Run) {
    $state = Get-RunState $Run
    if ($Run.reason) { $state += " ($($Run.reason))" }
    '{0,-40} {1,-22} {2,-25} {3}' -f $Run.id, $state, $Run.started, $Run.cwd
}

function Get-WorkerCommand { "powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\claude-worker.ps1`"" }

function Get-NextStepAdvice($Run, [string]$State) {
    $setKey = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\set-worker-key.ps1`""
    switch ($(if ($State -eq 'failed') { $Run.reason } else { $State })) {
        'succeeded'   { return 'The run finished. Its final report is in the output file (`result` field).' }
        'running'     { return "The worker is still running (launcher PID $($Run.launcher_pid)). Wait for it before continuing anything." }
        'orphaned'    { return "Its launcher is gone but claude is still running (PID $($Run.claude_pid)) and may still be editing files. Wait for it to stop, or stop it, before -ResumeRun (which then needs -Force)." }
        'interrupted' { return 'The launcher stopped without recording an end (session closed, process killed or machine restarted). Continue the run.' }
        'killed'      { return 'The worker was stopped by a signal. Continue the run.' }
        'credit'      { return "The key's credit is exhausted. Ask the user to add credit or to store another key ($setKey), then continue the run." }
        'auth'        { return "The key was rejected (expired, revoked or invalid). Ask the user to store a valid key ($setKey), then continue the run." }
        'rate_limit'  { return 'Rate limited by the API. Continue the run in a few minutes.' }
        'overloaded'  { return 'The API was overloaded. Continue the run now; if it fails again, wait a few minutes.' }
        'server'      { return 'The API returned a server error. Continue the run now; if it fails again, wait a few minutes.' }
        'request'     { return 'The API refused the request (for example a prompt or context that is too long): read the detail before continuing.' }
        'network'     { return 'Network problem (connection refused, reset or timed out). Check the connection, then continue the run.' }
        'max_turns'   { return 'The worker reached --max-turns. Continue the run with a higher --max-turns.' }
        'budget'      { return 'The worker reached --max-budget-usd. Continue the run with a higher budget if the user agrees.' }
        'bg_timeout'  { return 'claude stopped background tasks (a workflow) before they finished. Continue the run.' }
        default       { return 'Unknown failure: read the last messages and stderr below before deciding.' }
    }
}

function Limit-Text([string]$Text, [int]$Max) {
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max) + "`n[... $($Text.Length - $Max) more characters]"
}

function Get-OneLine([string]$Text, [int]$Max) {
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max - 3) + '...' }
    return $t
}

function Get-ToolSummary([string]$Name, $Inputs) {
    if ($null -eq $Inputs) { return '' }
    if ($Name -eq 'Workflow') {
        $s = [string]$Inputs.script
        if ($s -match "name:\s*['""]([^'""]+)") { return "workflow $($Matches[1])" }
        if ($Inputs.name) { return "workflow $($Inputs.name)" }
        if ($Inputs.scriptPath) { return [string]$Inputs.scriptPath }
    }
    foreach ($k in 'command', 'file_path', 'notebook_path', 'pattern', 'description', 'url', 'query', 'subject', 'prompt') {
        $v = $Inputs.$k
        if ($v) { return (Get-OneLine ([string]$v) 160) }
    }
    try { return (Get-OneLine ($Inputs | ConvertTo-Json -Compress -Depth 4) 160) } catch { return '' }
}

# The transcript digest: progress (task list, workflows, sub-agents), files changed, last
# messages and tool calls. Same sections as claude-worker-digest.py on macOS/Linux.
function Get-TranscriptDigest([string]$Transcript) {
    $texts = New-Object Collections.Generic.List[object]
    $calls = New-Object Collections.Generic.List[object]
    $files = [ordered]@{}
    $todos = $null
    $agents = New-Object Collections.Generic.List[string]
    $addFile = {
        param($path, $tool, $who)
        if (-not $path) { return }
        if (-not $files.Contains($path)) { $files[$path] = [ordered]@{} }
        $key = if ($who) { "$tool ($who)" } else { $tool }
        if ($files[$path].Contains($key)) { $files[$path][$key]++ } else { $files[$path][$key] = 1 }
    }
    $launched = @{}   # runId -> the Workflow tool's own result (name, script), known from the launch
    foreach ($l in [IO.File]::ReadLines($Transcript, $script:RunsUtf8)) {
        if ($l.Contains('"toolUseResult"') -and $l.Contains('"runId":"wf_')) {
            try {
                $r = ($l | ConvertFrom-Json).toolUseResult
                if ($r.runId) { $launched[[string]$r.runId] = $r }
            }
            catch {}
            continue
        }
        if (-not $l.Contains('"type":"assistant"')) { continue }
        try { $j = $l | ConvertFrom-Json } catch { continue }
        if ($j.type -ne 'assistant' -or $j.isApiErrorMessage) { continue }
        foreach ($c in @($j.message.content)) {
            if ($c.type -eq 'text' -and "$($c.text)".Trim()) {
                $texts.Add(@($j.timestamp, [string]$c.text)); if ($texts.Count -gt 6) { $texts.RemoveAt(0) }
            }
            elseif ($c.type -eq 'tool_use') {
                $calls.Add(@($j.timestamp, [string]$c.name, (Get-ToolSummary $c.name $c.input))); if ($calls.Count -gt 25) { $calls.RemoveAt(0) }
                if ($script:EditTools -contains $c.name) {
                    $p = if ($c.input.file_path) { $c.input.file_path } else { $c.input.notebook_path }
                    & $addFile ([string]$p) $c.name ''
                }
                if ($c.name -eq 'TodoWrite') { $todos = @($c.input.todos) }
                if ($c.name -eq 'Agent' -or $c.name -eq 'Task') {
                    $d = if ($c.input.description) { $c.input.description } else { Get-OneLine ([string]$c.input.prompt) 80 }
                    $agents.Add([string]$d)
                }
            }
        }
    }

    # Sub-agents and workflow agents write their own transcripts next to the session's
    $sessionDir = Join-Path ([IO.Path]::GetDirectoryName($Transcript)) ([IO.Path]::GetFileNameWithoutExtension($Transcript))
    $subDir = Join-Path $sessionDir 'subagents'
    if (Test-Path -LiteralPath $subDir) {
        foreach ($f in Get-ChildItem -LiteralPath $subDir -Recurse -File -Filter '*.jsonl') {
            if ($f.Name -eq 'journal.jsonl') { continue }
            foreach ($l in [IO.File]::ReadLines($f.FullName, $script:RunsUtf8)) {
                if (-not $l.Contains('"tool_use"') -or $l -notmatch '"name":"(Edit|Write|MultiEdit|NotebookEdit)"') { continue }
                try { $j = $l | ConvertFrom-Json } catch { continue }
                if ($j.type -ne 'assistant') { continue }
                foreach ($c in @($j.message.content)) {
                    if ($c.type -eq 'tool_use' -and $script:EditTools -contains $c.name) {
                        $p = if ($c.input.file_path) { $c.input.file_path } else { $c.input.notebook_path }
                        & $addFile ([string]$p) $c.name 'sub-agent'
                    }
                }
            }
        }
    }

    # Workflows: <session>\workflows\<runId>.json (status, name) and <session>\subagents\workflows\<runId>\journal.jsonl
    $wfIds = [ordered]@{}
    $wfJsonDir = Join-Path $sessionDir 'workflows'
    if (Test-Path -LiteralPath $wfJsonDir) { Get-ChildItem -LiteralPath $wfJsonDir -File -Filter 'wf_*.json' | ForEach-Object { $wfIds[$_.BaseName] = 1 } }
    $wfAgentsDir = Join-Path $subDir 'workflows'
    if (Test-Path -LiteralPath $wfAgentsDir) { Get-ChildItem -LiteralPath $wfAgentsDir -Directory -Filter 'wf_*' | ForEach-Object { $wfIds[$_.Name] = 1 } }
    foreach ($id in $launched.Keys) { $wfIds[$id] = 1 }
    $wfLines = New-Object Collections.Generic.List[string]
    foreach ($id in $wfIds.Keys) {
        # <runId>.json is only written when the workflow ends
        $name = ''; $status = 'no end record (still running when the worker stopped)'; $wfScript = ''; $err = ''
        if ($launched.ContainsKey($id)) { $name = [string]$launched[$id].workflowName; $wfScript = [string]$launched[$id].scriptPath }
        $meta = Join-Path $wfJsonDir "$id.json"
        if (Test-Path -LiteralPath $meta) {
            try {
                $w = [IO.File]::ReadAllText($meta, $script:RunsUtf8) | ConvertFrom-Json
                if ($w.workflowName) { $name = [string]$w.workflowName }
                $status = if ($w.status) { [string]$w.status } else { 'unknown' }
                if ($w.scriptPath) { $wfScript = [string]$w.scriptPath }
                if ($w.error) { $err = Get-OneLine ([string]$w.error) 200 }
            }
            catch {}
        }
        $started = [ordered]@{}; $done = @{}
        $journal = Join-Path $wfAgentsDir "$id\journal.jsonl"
        if (Test-Path -LiteralPath $journal) {
            foreach ($l in [IO.File]::ReadLines($journal, $script:RunsUtf8)) {
                try { $e = $l | ConvertFrom-Json } catch { continue }
                if ($e.type -eq 'started' -and $e.agentId) { $started[[string]$e.agentId] = [string]$e.label }
                elseif ($e.type -eq 'result' -and $e.agentId) { $done[[string]$e.agentId] = 1 }
            }
        }
        $open = @($started.Keys | Where-Object { -not $done.ContainsKey($_) } | ForEach-Object { $started[$_] })
        $line = "- ``$id``"
        if ($name) { $line += " $name" }
        $line += " - status $status, $($done.Count)/$($started.Count) agents finished"
        if ($open.Count) { $line += '; unfinished: ' + (($open | Select-Object -First 15) -join ', ') + $(if ($open.Count -gt 15) { ", ... ($($open.Count) in all)" } else { '' }) }
        if ($err) { $line += "; error: $err" }
        if ($wfScript) { $line += "; script: $wfScript" }
        $wfLines.Add($line)
    }

    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('## Progress')
    [void]$sb.AppendLine()
    $any = $false
    if ($todos) {
        $any = $true
        [void]$sb.AppendLine('Task list (last TodoWrite):')
        foreach ($t in $todos) {
            $box = switch ($t.status) { 'completed' { '[x]' } 'in_progress' { '[~]' } default { '[ ]' } }
            [void]$sb.AppendLine("- $box $($t.content)")
        }
        [void]$sb.AppendLine()
    }
    if ($wfLines.Count) {
        $any = $true
        [void]$sb.AppendLine('Workflows started by the worker (a resumed worker can try `resumeFromRunId` with these ids):')
        foreach ($l in $wfLines) { [void]$sb.AppendLine($l) }
        [void]$sb.AppendLine()
    }
    if ($agents.Count) {
        $any = $true
        [void]$sb.AppendLine("Sub-agents started with the Agent tool: $($agents.Count) (last ones: " + ((@($agents) | Select-Object -Last 8) -join '; ') + ')')
        [void]$sb.AppendLine()
    }
    if (-not $any) { [void]$sb.AppendLine('No task list, workflow or sub-agent recorded.'); [void]$sb.AppendLine() }

    [void]$sb.AppendLine('## Files the worker changed (from its tool calls)')
    [void]$sb.AppendLine()
    if ($files.Count) {
        $n = 0
        foreach ($p in $files.Keys) {
            $n++
            if ($n -gt 150) { [void]$sb.AppendLine("- ... and $($files.Count - 150) more"); break }
            $ops = @($files[$p].Keys | ForEach-Object { "$_ x$($files[$p][$_])" }) -join ', '
            [void]$sb.AppendLine("- $p - $ops")
        }
    }
    else { [void]$sb.AppendLine('None recorded.') }
    [void]$sb.AppendLine()

    [void]$sb.AppendLine('## Last messages from the worker (oldest first)')
    [void]$sb.AppendLine()
    if ($texts.Count) { foreach ($t in $texts) { [void]$sb.AppendLine("### $($t[0])"); [void]$sb.AppendLine((Limit-Text $t[1] 2000)); [void]$sb.AppendLine() } }
    else { [void]$sb.AppendLine('None.'); [void]$sb.AppendLine() }

    [void]$sb.AppendLine('## Last tool calls (oldest first)')
    [void]$sb.AppendLine()
    if ($calls.Count) { foreach ($c in $calls) { [void]$sb.AppendLine("- $($c[0]) $($c[1]): $($c[2])") } }
    else { [void]$sb.AppendLine('None.') }
    return $sb.ToString()
}

function Get-RunReport($Run) {
    $state = Get-RunState $Run
    $sb = New-Object Text.StringBuilder
    $statusText = $state
    if ($state -eq 'failed') { $statusText = "failed ($($Run.reason)): $($Run.detail)" }
    $fast = if ($Run.fast -eq '1') { ' (fast mode requested)' } else { '' }
    [void]$sb.AppendLine("# Worker run $($Run.id)")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("- Status: $statusText")
    if ($Run.name) { [void]$sb.AppendLine("- Name: $($Run.name)") }
    [void]$sb.AppendLine("- Session: $($Run.session_id) - model $($Run.model)$fast - attempts $($Run.attempts)")
    [void]$sb.AppendLine("- Folder: $($Run.cwd)")
    [void]$sb.AppendLine("- Started: $($Run.started) - last start $($Run.last_start) - ended $($Run.ended) - exit code $($Run.exit_code)")
    if ($Run.out_file) { [void]$sb.AppendLine("- Output file: $($Run.out_file)") }
    $transcript = Find-RunTranscript $Run
    if ($transcript) { [void]$sb.AppendLine("- Transcript: $transcript") }
    else { [void]$sb.AppendLine("- Transcript: none found for this session under $(Join-Path (Get-ClaudeConfigDir) 'projects')") }
    [void]$sb.AppendLine("- Run files: $($Run.dir)")
    [void]$sb.AppendLine()

    [void]$sb.AppendLine('## What to do next')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine((Get-NextStepAdvice $Run $state))
    if ($state -ne 'succeeded' -and $state -ne 'running') {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("To continue the same worker with its whole conversation (billed to the key): ``$(Get-WorkerCommand) -ResumeRun $($Run.id)``, in the background like the first launch. It reuses the model, folder, options and output file; add ``-Prompt `"...`"`` to give other instructions. Prefer this to a new worker, which would start without any of this context.")
    }
    [void]$sb.AppendLine()

    [void]$sb.AppendLine('## Brief')
    [void]$sb.AppendLine()
    $brief = Join-Path $Run.dir 'prompt.md'
    if (Test-Path -LiteralPath $brief) { [void]$sb.AppendLine((Limit-Text ([IO.File]::ReadAllText($brief, $script:RunsUtf8)) 20000)) }
    else { [void]$sb.AppendLine('Not recorded.') }
    [void]$sb.AppendLine()

    if ($transcript) { [void]$sb.Append((Get-TranscriptDigest $transcript)); [void]$sb.AppendLine() }

    [void]$sb.AppendLine('## Git')
    [void]$sb.AppendLine()
    $git = Get-GitInfo $Run.cwd
    if ($git.root) {
        $start = if ($Run.git_head) { $Run.git_head } else { '' }
        if ($start) {
            [void]$sb.AppendLine("Commits since the run started ($($start.Substring(0, [Math]::Min(12, $start.Length)))):")
            [void]$sb.AppendLine('```')
            [void]$sb.AppendLine(((& git -C $git.root log --oneline "$start..HEAD" 2>$null | Select-Object -First 50) -join "`n"))
            [void]$sb.AppendLine('```')
            [void]$sb.AppendLine("Changes since then (committed or not, ``git diff --stat $($start.Substring(0, [Math]::Min(12, $start.Length)))``):")
            [void]$sb.AppendLine('```')
            [void]$sb.AppendLine(((& git -C $git.root diff --stat $start 2>$null | Select-Object -Last 80) -join "`n"))
            [void]$sb.AppendLine('```')
        }
        [void]$sb.AppendLine('`git status --porcelain` now:')
        [void]$sb.AppendLine('```')
        [void]$sb.AppendLine(((& git -C $git.root status --porcelain 2>$null | Select-Object -First 80) -join "`n"))
        [void]$sb.AppendLine('```')
        $before = Join-Path $Run.dir 'git-start.txt'
        if ((Test-Path -LiteralPath $before) -and (Get-Item -LiteralPath $before).Length) { [void]$sb.AppendLine("Files already modified before the run started: $before") }
    }
    else { [void]$sb.AppendLine('Not a git repository.') }
    [void]$sb.AppendLine()

    [void]$sb.AppendLine('## Stderr (last lines)')
    [void]$sb.AppendLine()
    $errLog = Join-Path $Run.dir 'stderr.log'
    $tail = @()
    if (Test-Path -LiteralPath $errLog) { $tail = @([IO.File]::ReadAllLines($errLog, $script:RunsUtf8) | Where-Object { $_.Trim() } | Select-Object -Last 20) }
    if ($tail.Count) { [void]$sb.AppendLine('```'); foreach ($l in $tail) { [void]$sb.AppendLine($l) }; [void]$sb.AppendLine('```') }
    else { [void]$sb.AppendLine('Empty.') }
    return $sb.ToString()
}

function Get-ResumePrompt($Run) {
    $why = if ($Run.status -eq 'failed') { "$($Run.reason): $($Run.detail)" } else { (Get-RunState $Run) }
    return @"
Your previous run stopped before the end ($why). You still have your whole conversation, but files may have changed since, and any workflow or sub-agent you had started was stopped with you.
First check the current state of the files you were working on (and ``git status`` if this is a git repository). Then finish the original task without redoing work that is already done. If a workflow was unfinished, resume it with resumeFromRunId if the Workflow tool accepts it; otherwise start a new workflow that covers only what is left.
End with the final report the original brief asked for, including the files written by the earlier attempt.
"@
}
