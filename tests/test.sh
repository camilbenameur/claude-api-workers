#!/usr/bin/env bash
# Tests for the bash scripts: temporary HOME, fake keys, and a stub `claude` that reports what it
# received instead of calling the API. Run: bash tests/test.sh
set -u
repo=$(cd "$(dirname "$0")/.." && pwd)
bin="$repo/bin"
pass=0 failed=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
ko() { failed=$((failed + 1)); echo "FAIL - $1"; }
check() { if eval "$2"; then ok "$1"; else ko "$1"; fi; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" CLAUDE_WORKER_HOME="$tmp/store"
unset XDG_CONFIG_HOME CLAUDE_CONFIG_DIR CLAUDE_WORKER CLAUDE_WORKER_KEY_HELPER CLAUDE_WORKER_BASE_URL ANTHROPIC_API_KEY
mkdir -p "$HOME/proj/node_modules/pkg" "$HOME/other" "$tmp/stub"

k1="sk-ant-api03-$(printf 'A%.0s' $(seq 1 40))1111"
k2="sk-ant-api03-$(printf 'B%.0s' $(seq 1 40))2222"
k3="sk-ant-api03-$(printf 'C%.0s' $(seq 1 40))3333"
k4="sk-ant-api03-$(printf 'D%.0s' $(seq 1 40))4444"
printf 'OTHER=1\nANTHROPIC_API_KEY=%s\n' "$k1" > "$HOME/proj/.env"
printf 'export ANTHROPIC_API_KEY="%s"\n' "$k1" > "$HOME/.zshrc"
printf 'ANTHROPIC_API_KEY=%s\n' "$k2" > "$HOME/other/.env.local"
printf 'ANTHROPIC_API_KEY=%s\n' "$k3" > "$HOME/proj/node_modules/pkg/.env"
export FAKE_TEST_KEY="$k4"

. "$bin/claude-worker-lib.sh"
fp1=$(cw_fingerprint "$k1"); fp2=$(cw_fingerprint "$k2"); fp3=$(cw_fingerprint "$k3"); fp4=$(cw_fingerprint "$k4")

# --- find-api-keys
out=$("$bin/find-api-keys" --json)
check "finds the key in .env and .zshrc"       '[[ $out == *"$fp1"* ]]'
check "finds the key in .env.local"            '[[ $out == *"$fp2"* ]]'
check "finds the key in an env variable"       '[[ $out == *"$fp4"* && $out == *"env:FAKE_TEST_KEY"* ]]'
check "skips node_modules"                     '[[ $out != *"$fp3"* ]]'
check "never prints a full key"                '[[ $out != *"$k1"* && $out != *"$k2"* && $out != *"$k4"* ]]'
check "dedupes one key found twice"            '[ "$(printf "%s" "$out" | grep -o "\"fingerprint\": \"$fp1\"" | wc -l | tr -d " ")" = 1 ]'
check "lists both places for the deduped key"  '[[ $out == *"proj/.env:2"* && $out == *".zshrc:1"* ]]'
check "JSON parses"                            'printf "%s" "$out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null || ! command -v python3 >/dev/null'
text=$("$bin/find-api-keys")
check "text mode is masked too"                '[[ $text != *"$k1"* && $text == *"...1111"* ]]'

# --- set-worker-key
"$bin/set-worker-key" --from "${fp1:0:10}" --no-check > /dev/null
check "stores the key chosen by fingerprint"   '[ "$(cat "$CLAUDE_WORKER_HOME/key")" = "$k1" ]'
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) ;; *)
    check "key file is mode 600"               '[ "$(ls -l "$CLAUDE_WORKER_HOME/key" | cut -c1-10)" = "-rw-------" ]' ;;
esac
status=$("$bin/set-worker-key" --status --no-check)
check "status is masked"                       '[[ $status != *"$k1"* && $status == *"$fp1"* ]]'
check "find-api-keys marks the stored key"     '[[ $("$bin/find-api-keys" --json) == *"\"stored\": true"* ]]'
"$bin/set-worker-key" --from deadbeef00 --no-check > /dev/null 2>&1
check "unknown fingerprint is refused"         '[ $? = 2 ]'
"$bin/set-worker-key" --from abc > /dev/null 2>&1
check "too-short fingerprint is refused"       '[ $? = 2 ]'

# --- claude-worker, with a stub claude
cat > "$tmp/stub/claude" <<'STUB'
#!/usr/bin/env bash
stdin=$(cat)
case " $* " in *" stream-json "*)
    echo '{"type":"system","subtype":"init","apiKeySource":"ANTHROPIC_API_KEY"}'
    echo '{"type":"result","result":"worker OK","total_cost_usd":0.001}'
    exit 0 ;;
esac
arg() { _n=$1; shift; while [ $# -gt 0 ]; do [ "$1" = "$_n" ] && { printf '%s' "${2:-}"; return; }; shift; done; }
sid=$(arg --session-id "$@"); [ -n "$sid" ] || sid=$(arg --resume "$@")
mode=${STUB_MODE:-}
proj="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/stub-proj"
asst() { printf '{"type":"assistant","timestamp":"2026-10-29T10:00:00Z","message":{"content":[%s]}}\n' "$1"; }
if [ -n "$sid" ] && [ "$mode" != nosave ]; then
    mkdir -p "$proj"; t="$proj/$sid.jsonl"
    echo '{"type":"user","message":{"content":"prompt"}}' >> "$t"
    if [ "$mode" = credit ]; then
        asst '{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"step one","status":"completed"},{"content":"step two","status":"in_progress"}]}}' >> "$t"
        asst '{"type":"tool_use","name":"Edit","input":{"file_path":"/proj/main-é.txt","old_string":"a","new_string":"b"}}' >> "$t"
        asst '{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}' >> "$t"
        asst '{"type":"text","text":"Step one done, starting step two."}' >> "$t"
        echo '{"type":"assistant","isApiErrorMessage":true,"error":"billing_error","apiErrorStatus":400,"message":{"content":[{"type":"text","text":"Credit balance is too low"}]}}' >> "$t"
        wd="$proj/$sid/subagents/workflows/wf_stub-1"; mkdir -p "$wd" "$proj/$sid/workflows"
        printf '%s\n' '{"type":"launched"}' '{"type":"started","agentId":"a1","label":"fix:1"}' '{"type":"started","agentId":"a2","label":"fix:2"}' '{"type":"result","agentId":"a1","result":"ok"}' > "$wd/journal.jsonl"
        asst '{"type":"tool_use","name":"Write","input":{"file_path":"/proj/from-agent.txt","content":"x"}}' > "$wd/agent-a1.jsonl"
        echo '{"runId":"wf_stub-1","workflowName":"stub-fixes","status":"running","scriptPath":"/s/wf.js"}' > "$proj/$sid/workflows/wf_stub-1.json"
    else
        asst '{"type":"text","text":"done"}' >> "$t"
    fi
fi
case $mode in
    hang) exec sleep 120 ;;
    credit)
        echo "stub warning line" >&2
        printf '{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","api_error_status":400,"result":"Credit balance is too low","session_id":"%s"}\n' "$sid"
        exit 1 ;;
esac
echo "KEYFP=$(printf '%s' "${ANTHROPIC_API_KEY:-}" | (sha256sum 2>/dev/null || shasum -a 256) | cut -c1-12)"
echo "LEAK=${CLAUDE_CODE_FAKE:-none}/${ANTHROPIC_BASE_URL:-none}/${CLAUDECODE:-none}"
echo "WORKER=${CLAUDE_WORKER:-}"
echo "KEEP=${CLAUDE_CODE_GIT_BASH_PATH:-none}/${CLAUDE_CODE_KEEPME:-none}"
echo "BGWAIT=${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-none}"
r=$(arg --resume "$@"); echo "RESUME=${r:-none}"
echo "PWD=$PWD"
echo "ARGS=$*"
echo "STDIN=$stdin"
[ "$mode" = nosave ] && exit 7
exit 0
STUB
chmod +x "$tmp/stub/claude"
export PATH="$tmp/stub:$PATH"
export CLAUDE_CODE_FAKE=leak ANTHROPIC_BASE_URL=http://example.invalid CLAUDECODE=1 CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=600000
export CLAUDE_CODE_GIT_BASH_PATH=/opt/git/bash CLAUDE_CODE_KEEPME=yes CLAUDE_WORKER_KEEP_ENV=CLAUDE_CODE_KEEPME
mkdir -p "$tmp/work dir"
out=$("$bin/claude-worker" --prompt "héllo \"quoted\"" --cwd "$tmp/work dir" --output-format json --json-schema '{"a":"b c"}')
check "worker gets the stored key"             '[[ $out == *"KEYFP=$fp1"* ]]'
check "parent session variables are dropped"   '[[ $out == *"LEAK=none/none/none"* ]]'
check "recursion marker is set"                '[[ $out == *"WORKER=1"* ]]'
check "runs in --cwd (with a space)"           '[[ $out == *"PWD=$tmp/work dir"* ]]'
check "prompt arrives on stdin intact"         '[[ $out == *"STDIN=héllo \"quoted\""* ]]'
check "unknown options reach claude"           '[[ $out == *"--output-format json --json-schema {\"a\":\"b c\"}"* ]]'
check "parent environment is untouched"        '[ "$CLAUDE_CODE_FAKE" = leak ]'
check "keeps GIT_BASH_PATH and KEEP_ENV names" '[[ $out == *"KEEP=/opt/git/bash/yes"* ]]'
check "waits for background workflows"         '[[ $out == *"BGWAIT=0"* ]]'

# --- run records and crash recovery
. "$bin/claude-worker-runs.sh"
check "a session id is given to claude"        '[[ $out == *"--session-id "[0-9a-f]* ]]'
out=$(STUB_MODE=credit "$bin/claude-worker" --prompt "brief text" --name job1 --model opus --out-file "$tmp/c.json" --output-format json 2>&1)
code=$?
cw_run_find job1; job_id=$R_id job_sid=$R_session_id
check "run id announced on stderr"             '[[ $out == *"claude-worker: run $job_id"* ]]'
check "a failed run exits non-zero"            '[ "$code" = 1 ]'
check "the failure reason is printed"          '[[ $out == *"failed (credit): Credit balance is too low"* && $out == *"--resume-run $job_id"* ]]'
check "the run record says failed (credit)"    '[ "$R_status" = failed ] && [ "$R_reason" = credit ] && [ "$R_model" = opus ]'
rep=$("$bin/claude-worker" --recover job1)
check "--recover shows status and advice"      '[[ $rep == *"Status: failed (credit)"* && $rep == *"add credit"* ]]'
check "--recover shows the brief"              '[[ $rep == *"brief text"* ]]'
if command -v python3 >/dev/null 2>&1; then
    check "--recover shows the task list"      '[[ $rep == *"- [x] step one"* && $rep == *"- [~] step two"* ]]'
    check "--recover lists files, sub-agents too" '[[ $rep == *"main-é.txt - Edit x1"* && $rep == *"from-agent.txt - Write (sub-agent) x1"* ]]'
    check "--recover shows unfinished workflows" '[[ $rep == *"wf_stub-1"* && $rep == *"stub-fixes"* && $rep == *"1/2 agents finished; unfinished: fix:2"* ]]'
    check "--recover shows messages and calls" '[[ $rep == *"Step one done, starting step two."* && $rep == *"Bash: npm test"* ]]'
else
    echo "skip - transcript digest (no python3)"
fi
check "--recover shows stderr"                 '[[ $rep == *"stub warning line"* ]]'
check "--recover saves report.md"              'grep -q "brief text" "$CLAUDE_WORKER_HOME/runs/$job_id/report.md"'
check "--recover last finds the latest run"    '[[ $("$bin/claude-worker" --recover last) == *"Worker run $job_id"* ]]'
"$bin/claude-worker" --recover nope > /dev/null 2>&1
check "--recover with no match exits 2"        '[ $? = 2 ]'
"$bin/claude-worker" --resume-run job1 > /dev/null 2>&1
code=$?
co=$(cat "$tmp/c.json")
check "--resume-run continues the same session" '[ "$code" = 0 ] && [[ $co == *"RESUME=$job_sid"* && $co != *"--session-id"* ]]'
check "--resume-run replays model and options" '[[ $co == *"--model opus"* && $co == *"--output-format json"* ]]'
check "--resume-run says what happened"        '[[ $co == *"STDIN=Your previous run stopped before the end (credit: Credit balance is too low)"* ]]'
cw_run_find job1
check "resumed run is recorded"                '[ "$R_status" = succeeded ] && [ "$R_attempts" = 2 ] && [ -f "$R_dir/resume-2.md" ]'
runs=$("$bin/claude-worker" --runs)
check "--runs lists the runs"                  '[[ $runs == *"$job_id"* && $runs == *"succeeded"* ]]'

STUB_MODE=nosave "$bin/claude-worker" --prompt "original brief" --name job2 > /dev/null 2>&1
code=$?
cw_run_find job2; job2_sid=$R_session_id
check "unknown failure is recorded"            '[ "$code" = 7 ] && [ "$R_status" = failed ] && [ "$R_reason" = unknown ]'
out=$("$bin/claude-worker" --resume-run job2 2>/dev/null)
check "no transcript: resume replays the brief" '[[ $out == *"--session-id $job2_sid"* && $out == *"RESUME=none"* && $out == *"STDIN=original brief"* ]]'

wait_pid_recorded() {  # $1 run name: waits until the launcher has recorded claude's PID
    for _i in $(seq 1 40); do cw_run_find "$1" && [ -n "$R_claude_pid" ] && return 0; sleep 0.25; done; return 1
}
STUB_MODE=hang "$bin/claude-worker" --prompt x --name job3 > /dev/null 2>&1 &
launcher=$!
wait_pid_recorded job3
check "a running run is listed as running"     '[ "$(cw_run_state)" = running ]'
kill -TERM "$launcher"; wait "$launcher" 2>/dev/null
cw_run_find job3
check "TERM on the launcher stops claude too"  '[ "$R_status" = failed ] && [ "$R_reason" = killed ] && ! cw_pid_alive "$R_claude_pid"'

STUB_MODE=hang "$bin/claude-worker" --prompt x --name job4 > /dev/null 2>&1 &
launcher=$!
wait_pid_recorded job4; stub_pid=$R_claude_pid
kill -KILL "$launcher"; wait "$launcher" 2>/dev/null
cw_run_find job4
check "launcher killed, claude alive: orphaned" '[ "$(cw_run_state)" = orphaned ]'
"$bin/claude-worker" --resume-run job4 > /dev/null 2>&1
check "--resume-run refuses an orphaned run"   '[ $? = 2 ]'
kill -KILL "$stub_pid" 2>/dev/null; sleep 0.5
cw_run_find job4
check "both gone: interrupted"                 '[ "$(cw_run_state)" = interrupted ]'
out=$("$bin/claude-worker" --resume-run job4 2>/dev/null)
check "--resume-run continues an interrupted run" '[[ $out == *"RESUME=$R_session_id"* && $out == *"(interrupted)"* ]]'
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) ;; *)
    ln -s "$bin/claude-worker" "$tmp/cw-link"
    check "works when called through a symlink" '[[ $("$tmp/cw-link" --prompt x) == *"KEYFP=$fp1"* ]]' ;;
esac
printf 'from a file' > "$tmp/brief.md"
"$bin/claude-worker" --prompt-file "$tmp/brief.md" --out-file "$tmp/out.txt" > /dev/null
check "--prompt-file and --out-file"           'grep -q "STDIN=from a file" "$tmp/out.txt"'
check "--self-test passes"                     '"$bin/claude-worker" --self-test > /dev/null'
check "--fast sends the fast mode settings"    '[[ $("$bin/claude-worker" --prompt x --model opus --fast) == *"--model opus"*"--settings "* ]]'
CLAUDE_WORKER=1 "$bin/claude-worker" --prompt x > /dev/null 2>&1
check "refuses to run inside a worker (3)"     '[ $? = 3 ]'
"$bin/claude-worker" --prompt x --cwd "$tmp/nope" > /dev/null 2>&1
check "missing cwd exits 2"                    '[ $? = 2 ]'
CLAUDE_WORKER_KEY_HELPER="printf '%s' '$k2'" "$bin/claude-worker" --prompt x > "$tmp/h.txt"
check "CLAUDE_WORKER_KEY_HELPER wins"          'grep -q "KEYFP=$fp2" "$tmp/h.txt"'
"$bin/set-worker-key" --remove > /dev/null
"$bin/claude-worker" --prompt x > /dev/null 2>&1
check "no stored key exits 2"                  '[ $? = 2 ]'
unset CLAUDE_CODE_FAKE ANTHROPIC_BASE_URL CLAUDECODE CLAUDE_CODE_GIT_BASH_PATH CLAUDE_CODE_KEEPME CLAUDE_WORKER_KEEP_ENV CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS
check "find-api-keys --help has no code line"  '! "$bin/find-api-keys" --help | grep -q "set -u"'

# --- install.sh (not on Windows shells: install.ps1 covers those)
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) echo "skip - install.sh tests (Windows shell)" ;; *)
    printf '# My rules\n\nKeep this.\n' > "$HOME/.claude.md.seed"
    mkdir -p "$HOME/.claude" && cp "$HOME/.claude.md.seed" "$HOME/.claude/CLAUDE.md"
    bash "$repo/install.sh" > /dev/null && bash "$repo/install.sh" --mode on-request > /dev/null
    md=$(cat "$HOME/.claude/CLAUDE.md")
    check "install keeps the user's content"   '[[ $md == *"Keep this."* ]]'
    check "reinstall leaves a single block"    '[ "$(grep -c "claude-api-workers:begin" "$HOME/.claude/CLAUDE.md")" = 1 ]'
    check "mode on-request was applied"        '[[ $md == *"asks for \"API workers\""* ]]'
    check "no placeholder left"                '[[ $md != *"{{"* ]]'
    check "scripts are executable"             '[ -x "$HOME/.claude/claude-worker/bin/claude-worker" ]'
    check "recovery scripts are installed"     '[ -f "$HOME/.claude/claude-worker/bin/claude-worker-runs.sh" ] && [ -x "$HOME/.claude/claude-worker/bin/claude-worker-digest.py" ]'
    check "backup holds the original file"     'cmp -s "$HOME/.claude.md.seed" "$HOME/.claude/CLAUDE.md.bak-claude-api-workers"'
    check "installer is copied for uninstall"  '[ -x "$HOME/.claude/claude-worker/install.sh" ]'
    bash "$HOME/.claude/claude-worker/install.sh" > /dev/null
    check "reinstall from the installed copy"  '[ "$(grep -c "claude-api-workers:begin" "$HOME/.claude/CLAUDE.md")" = 1 ]'
    bash "$HOME/.claude/claude-worker/install.sh" --uninstall > /dev/null
    check "uninstall removes the block"        '! grep -q "claude-api-workers" "$HOME/.claude/CLAUDE.md"'
    check "uninstall keeps the user's content" 'grep -q "Keep this." "$HOME/.claude/CLAUDE.md"'
    check "uninstall removes the scripts"      '[ ! -e "$HOME/.claude/claude-worker" ]'

    mkdir -p "$tmp/tools" && echo mine > "$tmp/tools/keep.txt"
    bash "$repo/install.sh" --prefix "$tmp/tools" > /dev/null && bash "$repo/install.sh" --uninstall --prefix "$tmp/tools" > /dev/null
    check "uninstall spares foreign files"     '[ -f "$tmp/tools/keep.txt" ] && [ ! -e "$tmp/tools/bin" ]'

    printf '# Mine\n<!-- claude-api-workers:begin -->\nhalf block\n\nMy later rules.\n' > "$HOME/.claude/CLAUDE.md"
    bash "$repo/install.sh" > /dev/null 2>&1
    check "unbalanced markers are refused"     '[ $? = 2 ] && grep -q "My later rules." "$HOME/.claude/CLAUDE.md"'

    CLAUDE_CONFIG_DIR="$tmp/cfg" bash "$repo/install.sh" > /dev/null
    check "honours CLAUDE_CONFIG_DIR"          'grep -q "claude-api-workers:begin" "$tmp/cfg/CLAUDE.md" && [ -x "$tmp/cfg/claude-worker/bin/claude-worker" ]'

    printf '# Dotfiles\n' > "$tmp/dotfiles-claude.md"
    rm -f "$HOME/.claude/CLAUDE.md" && ln -s "$tmp/dotfiles-claude.md" "$HOME/.claude/CLAUDE.md"
    bash "$repo/install.sh" > /dev/null
    check "a symlinked CLAUDE.md stays a link" '[ -L "$HOME/.claude/CLAUDE.md" ] && grep -q "claude-api-workers:begin" "$tmp/dotfiles-claude.md"'
    ;;
esac

"$bin/set-worker-key" --no-check < /dev/null > /dev/null 2>&1
check "hidden prompt refuses to run without a terminal" '[ $? = 2 ]'

echo "$pass passed, $failed failed"
[ "$failed" = 0 ]
