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
unset XDG_CONFIG_HOME CLAUDE_WORKER CLAUDE_WORKER_KEY_HELPER CLAUDE_WORKER_BASE_URL ANTHROPIC_API_KEY
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
echo "KEYFP=$(printf '%s' "${ANTHROPIC_API_KEY:-}" | (sha256sum 2>/dev/null || shasum -a 256) | cut -c1-12)"
echo "LEAK=${CLAUDE_CODE_FAKE:-none}/${ANTHROPIC_BASE_URL:-none}/${CLAUDECODE:-none}"
echo "WORKER=${CLAUDE_WORKER:-}"
echo "KEEP=${CLAUDE_CODE_GIT_BASH_PATH:-none}/${CLAUDE_CODE_KEEPME:-none}"
echo "PWD=$PWD"
echo "ARGS=$*"
echo "STDIN=$stdin"
STUB
chmod +x "$tmp/stub/claude"
export PATH="$tmp/stub:$PATH"
export CLAUDE_CODE_FAKE=leak ANTHROPIC_BASE_URL=http://example.invalid CLAUDECODE=1
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
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) ;; *)
    ln -s "$bin/claude-worker" "$tmp/cw-link"
    check "works when called through a symlink" '[[ $("$tmp/cw-link" --prompt x) == *"KEYFP=$fp1"* ]]' ;;
esac
printf 'from a file' > "$tmp/brief.md"
"$bin/claude-worker" --prompt-file "$tmp/brief.md" --out-file "$tmp/out.txt" > /dev/null
check "--prompt-file and --out-file"           'grep -q "STDIN=from a file" "$tmp/out.txt"'
check "--self-test passes"                     '"$bin/claude-worker" --self-test > /dev/null'
CLAUDE_WORKER=1 "$bin/claude-worker" --prompt x > /dev/null 2>&1
check "refuses to run inside a worker (3)"     '[ $? = 3 ]'
"$bin/claude-worker" --prompt x --cwd "$tmp/nope" > /dev/null 2>&1
check "missing cwd exits 2"                    '[ $? = 2 ]'
CLAUDE_WORKER_KEY_HELPER="printf '%s' '$k2'" "$bin/claude-worker" --prompt x > "$tmp/h.txt"
check "CLAUDE_WORKER_KEY_HELPER wins"          'grep -q "KEYFP=$fp2" "$tmp/h.txt"'
"$bin/set-worker-key" --remove > /dev/null
"$bin/claude-worker" --prompt x > /dev/null 2>&1
check "no stored key exits 2"                  '[ $? = 2 ]'
unset CLAUDE_CODE_FAKE ANTHROPIC_BASE_URL CLAUDECODE CLAUDE_CODE_GIT_BASH_PATH CLAUDE_CODE_KEEPME CLAUDE_WORKER_KEEP_ENV
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
