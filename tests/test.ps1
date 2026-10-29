# Tests for the Windows scripts: temporary profile, fake keys, and a stub claude.exe (compiled on
# the fly) that reports what it received instead of calling the API.
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File tests\test.ps1
$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
$bin = Join-Path $repo 'bin'
$ps = (Get-Process -Id $PID).Path
$utf8 = New-Object Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8
$script:pass = 0; $script:failed = 0
function Check([string]$Name, [scriptblock]$Condition) {
    if (& $Condition) { $script:pass++; Write-Output "ok   - $Name" } else { $script:failed++; Write-Output "FAIL - $Name" }
}
# Runs a command in a child PowerShell (so env changes stay there), without native quoting games
function Invoke-Child([string]$Command) {
    $full = "[Console]::OutputEncoding = New-Object Text.UTF8Encoding `$false; $Command; exit `$LASTEXITCODE"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($full))
    $out = & $ps -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc 2>&1 | ForEach-Object { "$_" } | Out-String
    [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('caw-test-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
$saved = @{ USERPROFILE = $env:USERPROFILE; PATH = $env:PATH }
try {
    $fakeHome = Join-Path $tmp 'home'
    foreach ($d in "$fakeHome\proj\node_modules\pkg", "$fakeHome\other", "$tmp\stub", "$tmp\work dir") { New-Item -ItemType Directory -Force $d | Out-Null }
    $env:USERPROFILE = $fakeHome
    $env:CLAUDE_WORKER_HOME = Join-Path $tmp 'store'
    foreach ($v in 'CLAUDE_WORKER', 'CLAUDE_WORKER_BASE_URL', 'ANTHROPIC_API_KEY', 'CLAUDE_CONFIG_DIR') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }

    $k1 = 'sk-ant-api03-' + ('A' * 40) + '1111'
    $k2 = 'sk-ant-api03-' + ('B' * 40) + '2222'
    $k3 = 'sk-ant-api03-' + ('C' * 40) + '3333'
    $k4 = 'sk-ant-api03-' + ('D' * 40) + '4444'
    [IO.File]::WriteAllText("$fakeHome\proj\.env", "OTHER=1`nANTHROPIC_API_KEY=$k1`n")
    [IO.File]::WriteAllText("$fakeHome\.bashrc", "export ANTHROPIC_API_KEY=`"$k1`"`n")
    [IO.File]::WriteAllText("$fakeHome\other\.env.local", "ANTHROPIC_API_KEY=$k2`n")
    [IO.File]::WriteAllText("$fakeHome\proj\node_modules\pkg\.env", "ANTHROPIC_API_KEY=$k3`n")
    $env:FAKE_TEST_KEY = $k4

    . "$bin\claude-worker-lib.ps1"
    $fp1 = Get-KeyFingerprint $k1; $fp2 = Get-KeyFingerprint $k2; $fp3 = Get-KeyFingerprint $k3; $fp4 = Get-KeyFingerprint $k4

    # --- find-api-keys.ps1
    $r = Invoke-Child "& '$bin\find-api-keys.ps1' -Json -Root '$fakeHome'"
    $o = $r.Out
    $j = $o | ConvertFrom-Json
    $fps = @($j.candidates | ForEach-Object { $_.fingerprint })
    Check 'finds the key in .env and .bashrc'      { $fps -contains $fp1 }
    Check 'finds the key in .env.local'            { $fps -contains $fp2 }
    Check 'finds the key in an env variable'       { $fps -contains $fp4 -and $o.Contains('env:Process:FAKE_TEST_KEY') }
    Check 'skips node_modules'                     { $fps -notcontains $fp3 }
    Check 'never prints a full key'                { -not ($o.Contains($k1) -or $o.Contains($k2) -or $o.Contains($k4)) }
    Check 'dedupes one key found twice'            { @($fps | Where-Object { $_ -eq $fp1 }).Count -eq 1 }
    Check 'lists both places for the deduped key'  { $c = $j.candidates | Where-Object { $_.fingerprint -eq $fp1 }; @($c.sources).Count -eq 2 }
    $t = (Invoke-Child "& '$bin\find-api-keys.ps1' -Root '$fakeHome'").Out
    Check 'text mode is masked too'                { -not $t.Contains($k1) -and $t.Contains('...1111') }

    # --- set-worker-key.ps1
    $null = Invoke-Child "& '$bin\set-worker-key.ps1' -From '$($fp1.Substring(0, 10))' -NoCheck"
    Check 'stores the key chosen by fingerprint'   { (Read-StoredKey) -eq $k1 }
    Check 'key file is DPAPI, not clear text'      { -not ([IO.File]::ReadAllText((Get-WorkerKeyPath))).Contains('sk-ant') }
    $s = Invoke-Child "& '$bin\set-worker-key.ps1' -Status -NoCheck"
    Check 'status is masked'                       { -not $s.Out.Contains($k1) -and $s.Out.Contains($fp1) -and $s.Code -eq 0 }
    Check 'find-api-keys marks the stored key'     { ((Invoke-Child "& '$bin\find-api-keys.ps1' -Json -Root '$fakeHome'").Out | ConvertFrom-Json).stored_key -eq $fp1 }
    Check 'unknown fingerprint is refused'         { (Invoke-Child "& '$bin\set-worker-key.ps1' -From 'deadbeef00' -NoCheck").Code -eq 2 }
    Check 'too-short fingerprint is refused'       { (Invoke-Child "& '$bin\set-worker-key.ps1' -From 'abc'").Code -eq 2 }

    # --- claude-worker.ps1, with a stub claude.exe
    Add-Type -OutputType ConsoleApplication -OutputAssembly "$tmp\stub\claude.exe" -TypeDefinition @'
using System; using System.IO; using System.Text; using System.Security.Cryptography;
public static class Stub {
    public static int Main(string[] a) {
        var o = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)); o.AutoFlush = true;
        string stdin = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false)).ReadToEnd();
        if (Array.IndexOf(a, "stream-json") >= 0) {
            o.WriteLine("{\"type\":\"system\",\"subtype\":\"init\",\"apiKeySource\":\"ANTHROPIC_API_KEY\"}");
            o.WriteLine("{\"type\":\"result\",\"result\":\"worker OK\",\"total_cost_usd\":0.001}");
            return 0;
        }
        string key = Environment.GetEnvironmentVariable("ANTHROPIC_API_KEY") ?? "";
        var sb = new StringBuilder();
        foreach (byte b in SHA256.Create().ComputeHash(Encoding.UTF8.GetBytes(key))) sb.Append(b.ToString("x2"));
        Func<string, string> env = n => Environment.GetEnvironmentVariable(n) ?? "none";
        o.WriteLine("KEYFP=" + sb.ToString().Substring(0, 12));
        o.WriteLine("LEAK=" + env("CLAUDE_CODE_FAKE") + "/" + env("ANTHROPIC_BASE_URL") + "/" + env("CLAUDECODE"));
        o.WriteLine("WORKER=" + env("CLAUDE_WORKER"));
        o.WriteLine("KEEP=" + env("CLAUDE_CODE_GIT_BASH_PATH") + "/" + env("CLAUDE_CODE_KEEPME"));
        o.WriteLine("BGWAIT=" + env("CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS"));
        o.WriteLine("PWD=" + Environment.CurrentDirectory);
        o.WriteLine("ARGS=" + string.Join(" | ", a));
        o.WriteLine("STDIN=" + stdin.TrimEnd());
        return 0;
    }
}
'@
    $env:PATH = "$tmp\stub;$env:PATH"
    $env:CLAUDE_CODE_FAKE = 'leak'; $env:ANTHROPIC_BASE_URL = 'http://example.invalid'; $env:CLAUDECODE = '1'; $env:CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS = '600000'
    $env:CLAUDE_CODE_GIT_BASH_PATH = 'C:\Git\bin\bash.exe'; $env:CLAUDE_CODE_KEEPME = 'yes'; $env:CLAUDE_WORKER_KEEP_ENV = 'CLAUDE_CODE_KEEPME'
    [IO.File]::WriteAllText("$tmp\brief.md", "h$([char]0xE9)llo `"quoted`" from a file", $utf8)
    $w = Invoke-Child "& '$bin\claude-worker.ps1' -PromptFile '$tmp\brief.md' -Cwd '$tmp\work dir' --output-format json --json-schema '{`"a`":`"b c`"}'"
    $o = $w.Out
    Check 'worker gets the stored key'             { $o.Contains("KEYFP=$fp1") }
    Check 'parent session variables are dropped'   { $o.Contains('LEAK=none/none/none') }
    Check 'recursion marker is set'                { $o.Contains('WORKER=1') }
    Check 'runs in -Cwd (with a space)'            { $o.Contains("PWD=$tmp\work dir") }
    Check 'prompt arrives on stdin, accents intact' { $o.Contains("STDIN=h$([char]0xE9)llo `"quoted`" from a file") }
    Check 'inline JSON reaches claude intact'      { $o.Contains('--output-format | json | --json-schema | {"a":"b c"}') }
    Check 'parent environment is untouched'        { $env:CLAUDE_CODE_FAKE -eq 'leak' }
    Check 'keeps GIT_BASH_PATH and KEEP_ENV names'  { $o.Contains('KEEP=C:\Git\bin\bash.exe/yes') }
    Check 'waits for background workflows'         { $o.Contains('BGWAIT=0') }
    $ext = Invoke-Child "& '$bin\claude-worker.ps1' -Prompt x --foo -Model haiku bar"
    Check 'claude options are not bound to ours'   { $ext.Out.Contains('haiku | --append-system-prompt') -and $ext.Out.Contains('| --foo | bar') }
    $null = Invoke-Child "& '$bin\claude-worker.ps1' -Prompt 'caf$([char]0xE9)' -OutFile '$tmp\out.txt'"
    Check '-OutFile writes UTF-8 with accents'     { [IO.File]::ReadAllText("$tmp\out.txt", $utf8).Contains("STDIN=caf$([char]0xE9)") }
    $st = Invoke-Child "& '$bin\claude-worker.ps1' -SelfTest"
    Check '-SelfTest passes'                       { $st.Code -eq 0 -and $st.Out.Contains('apiKeySource=ANTHROPIC_API_KEY') }
    # Compare before/after: real workers running elsewhere keep their own fast-mode file
    $fastBefore = @(Get-ChildItem ([IO.Path]::GetTempPath()) -Filter 'claude-worker-fast-*.json' | ForEach-Object Name)
    $fw = Invoke-Child "& '$bin\claude-worker.ps1' -Prompt x -Model opus -Fast"
    $fastLeft = @(Get-ChildItem ([IO.Path]::GetTempPath()) -Filter 'claude-worker-fast-*.json' | Where-Object { $fastBefore -notcontains $_.Name })
    Check '-Fast sends the fast mode settings'     { $fw.Out.Contains('--model | opus') -and $fw.Out.Contains('| --settings |') -and $fastLeft.Count -eq 0 }
    Check 'refuses to run inside a worker (3)'     { (Invoke-Child "`$env:CLAUDE_WORKER = '1'; & '$bin\claude-worker.ps1' -Prompt x").Code -eq 3 }
    Check 'missing cwd exits 2'                    { (Invoke-Child "& '$bin\claude-worker.ps1' -Prompt x -Cwd '$tmp\nope'").Code -eq 2 }
    Check 'quote in cwd exits 2'                   { (Invoke-Child "& '$bin\claude-worker.ps1' -Prompt x -Cwd 'C:\x`" --model y'").Code -eq 2 }
    [IO.File]::WriteAllText((Get-WorkerKeyPath), 'garbage')
    Check 'corrupt key file exits 2'               { (Invoke-Child "& '$bin\claude-worker.ps1' -Prompt x").Code -eq 2 }
    $null = Invoke-Child "& '$bin\set-worker-key.ps1' -Remove"
    Check 'no stored key exits 2'                  { (Invoke-Child "& '$bin\claude-worker.ps1' -Prompt x").Code -eq 2 }
    foreach ($v in 'CLAUDE_CODE_FAKE', 'ANTHROPIC_BASE_URL', 'CLAUDECODE', 'CLAUDE_CODE_GIT_BASH_PATH', 'CLAUDE_CODE_KEEPME', 'CLAUDE_WORKER_KEEP_ENV', 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS') { Remove-Item "Env:$v" }
    $two = Invoke-Child "& '$ps' -NoProfile -ExecutionPolicy Bypass -File '$bin\find-api-keys.ps1' -Json -Root '$fakeHome\proj,$fakeHome\other'"
    Check '-Root a,b works through -File'          { $r2 = $two.Out | ConvertFrom-Json; @($r2.scanned.roots).Count -eq 2 -and @($r2.candidates.fingerprint) -contains $fp2 }

    # --- install.ps1
    $md = "$fakeHome\.claude\CLAUDE.md"
    New-Item -ItemType Directory -Force "$fakeHome\.claude" | Out-Null
    [IO.File]::WriteAllText($md, "# My rules`n`nKeep this.`n")
    $i1 = Invoke-Child "& '$repo\install.ps1'"
    $i2 = Invoke-Child "& '$repo\install.ps1' -Mode on-request"
    $text = [IO.File]::ReadAllText($md)
    Check 'install succeeds twice'                 { $i1.Code -eq 0 -and $i2.Code -eq 0 }
    Check "install keeps the user's content"       { $text.Contains('Keep this.') }
    Check 'reinstall leaves a single block'        { ([regex]::Matches($text, 'claude-api-workers:begin')).Count -eq 1 }
    Check 'mode on-request was applied'            { $text.Contains('asks for "API workers"') }
    Check 'no placeholder left'                    { -not $text.Contains('{{') }
    Check 'rule points at the installed scripts'   { $text.Contains("$fakeHome\.claude\claude-worker\bin\claude-worker.ps1") }
    Check 'scripts are installed'                  { Test-Path "$fakeHome\.claude\claude-worker\bin\claude-worker-lib.ps1" }
    Check 'backup holds the original file'         { [IO.File]::ReadAllText("$md.bak-claude-api-workers") -eq "# My rules`n`nKeep this.`n" }
    $i3 = Invoke-Child "& '$fakeHome\.claude\claude-worker\install.ps1'"
    Check 'reinstall from the installed copy'      { $i3.Code -eq 0 -and ([regex]::Matches([IO.File]::ReadAllText($md), 'claude-api-workers:begin')).Count -eq 1 }
    $u = Invoke-Child "& '$fakeHome\.claude\claude-worker\install.ps1' -Uninstall"
    $text = [IO.File]::ReadAllText($md)
    Check 'uninstall removes the block'            { $u.Code -eq 0 -and -not $text.Contains('claude-api-workers') }
    Check "uninstall keeps the user's content"     { $text.Contains('Keep this.') }
    Check 'uninstall removes the scripts'          { -not (Test-Path "$fakeHome\.claude\claude-worker") }

    New-Item -ItemType Directory -Force "$tmp\tools" | Out-Null; [IO.File]::WriteAllText("$tmp\tools\keep.txt", 'mine')
    $null = Invoke-Child "& '$repo\install.ps1' -Prefix '$tmp\tools'"
    $null = Invoke-Child "& '$repo\install.ps1' -Uninstall -Prefix '$tmp\tools'"
    Check 'uninstall spares foreign files'         { (Test-Path "$tmp\tools\keep.txt") -and -not (Test-Path "$tmp\tools\bin") }

    $null = Invoke-Child "`$env:CLAUDE_CONFIG_DIR = '$tmp\cfg'; & '$repo\install.ps1'"
    Check 'honours CLAUDE_CONFIG_DIR'              { (Test-Path "$tmp\cfg\claude-worker\bin\claude-worker.ps1") -and [IO.File]::ReadAllText("$tmp\cfg\CLAUDE.md").Contains('claude-api-workers:begin') }

    [IO.File]::WriteAllText($md, "# Mine`n<!-- claude-api-workers:begin -->`nhalf block`n`nMy later rules.`n")
    $bad = Invoke-Child "& '$repo\install.ps1'"
    Check 'unbalanced markers are refused'         { $bad.Code -ne 0 -and [IO.File]::ReadAllText($md).Contains('My later rules.') }
}
finally {
    $env:USERPROFILE = $saved.USERPROFILE; $env:PATH = $saved.PATH
    Remove-Item Env:CLAUDE_WORKER_HOME, Env:FAKE_TEST_KEY -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "$($script:pass) passed, $($script:failed) failed"
if ($script:failed -gt 0) { exit 1 }
