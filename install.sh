#!/usr/bin/env bash
# install.sh - install claude-api-workers for Claude Code on macOS and Linux.
#   ./install.sh [--mode always|on-request] [--prefix DIR]   install or update (idempotent)
#   ./install.sh --uninstall                                 remove scripts and the CLAUDE.md block
# Copies the scripts to ~/.claude/claude-worker and writes a marked block into ~/.claude/CLAUDE.md
# (backup kept as CLAUDE.md.bak-claude-api-workers). Never touches the stored API key.
set -eu
src=$(cd "$(dirname "$0")" && pwd)
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) echo "On Windows, run install.ps1 instead." >&2; exit 2 ;; esac

mode=always uninstall=0 prefix="$HOME/.claude/claude-worker"
while [ $# -gt 0 ]; do
    case $1 in
        --mode) [ $# -ge 2 ] || { echo "--mode needs a value" >&2; exit 2; }; mode=$2; shift 2 ;;
        --prefix) [ $# -ge 2 ] || { echo "--prefix needs a value" >&2; exit 2; }; prefix=$2; shift 2 ;;
        --uninstall) uninstall=1; shift ;;
        -h | --help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
case $mode in always | on-request) ;; *) echo "--mode must be always or on-request" >&2; exit 2 ;; esac

claude_dir="$HOME/.claude"
claude_md="$claude_dir/CLAUDE.md"
begin='<!-- claude-api-workers:begin -->'
end='<!-- claude-api-workers:end -->'
repo_url='https://github.com/camilbenameur/claude-api-workers'

# CLAUDE.md without our block, trailing blank lines trimmed by the command substitution
other_content() {
    [ -f "$claude_md" ] || return 0
    awk -v b="$begin" -v e="$end" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$claude_md"
}

save_claude_md() {
    mkdir -p "$claude_dir"
    [ -f "$claude_md" ] && cp -f "$claude_md" "$claude_md.bak-claude-api-workers"
    printf '%s' "$1" > "$claude_md.tmp" && mv -f "$claude_md.tmp" "$claude_md"
}

if [ "$uninstall" = 1 ]; then
    if [ -f "$claude_md" ]; then
        rest=$(other_content)
        if [ -n "$rest" ]; then save_claude_md "$rest"$'\n'; else save_claude_md ''; fi
    fi
    rm -rf "$prefix"
    echo "Removed $prefix and the claude-api-workers block from $claude_md."
    echo "The stored API key is kept. To delete it too, run set-worker-key --remove before uninstalling, or delete ${XDG_CONFIG_HOME:-$HOME/.config}/claude-worker/key."
    exit 0
fi

# 1. Scripts
bin="$prefix/bin"
mkdir -p "$bin"
for f in claude-worker set-worker-key find-api-keys claude-worker-lib.sh; do
    cp -f "$src/bin/$f" "$bin/$f"
done
chmod 755 "$bin/claude-worker" "$bin/set-worker-key" "$bin/find-api-keys"

# 2. Rule block (literal replacements: bash 5.2 would otherwise expand & in the values)
shopt -u patsub_replacement 2>/dev/null || true
rule=$(cat "$src/rules/rule.md")
mode_rule=$(cat "$src/rules/mode-$mode.md")
notes='   - A "claude.ai connectors are disabled" line on stderr is expected.'
run_example="\"$bin/claude-worker\" --prompt-file \"<brief.md>\" --model sonnet --cwd \"<project dir>\" --out-file \"<scratchpad>/out-<name>.json\" --permission-mode acceptEdits --output-format json"
rule=${rule//'{{MODE_RULE}}'/$mode_rule}
rule=${rule//'{{DATE}}'/$(date +%Y-%m-%d)}
rule=${rule//'{{REPO_URL}}'/$repo_url}
rule=${rule//'{{SHELL_TOOL}}'/Bash}
rule=${rule//'{{RUN_EXAMPLE}}'/$run_example}
rule=${rule//'{{PLATFORM_NOTES}}'/$notes}
rule=${rule//'{{SETKEY_CMD}}'/\"$bin/set-worker-key\"}
rule=${rule//'{{STATUS_CMD}}'/\"$bin/set-worker-key\" --status}
block="$begin"$'\n'"$rule"$'\n'"$end"

rest=$(other_content)
case $rest in *claude-worker*)
    echo "Warning: $claude_md already mentions claude-worker outside the claude-api-workers block: check for a duplicate rule." >&2 ;;
esac
if [ -n "$rest" ]; then save_claude_md "$rest"$'\n\n'"$block"$'\n'; else save_claude_md "$block"$'\n'; fi

echo "Installed claude-api-workers ($mode mode):"
echo "  scripts : $bin"
echo "  rule    : block added to $claude_md (backup: CLAUDE.md.bak-claude-api-workers)"
echo
echo "Next steps:"
echo "  find keys already on this machine (masked): \"$bin/find-api-keys\" --check"
echo "  store a key (the user runs it)            : \"$bin/set-worker-key\"   (or add --from <fingerprint>)"
echo "  check the worker                           : \"$bin/claude-worker\" --self-test"
command -v claude >/dev/null 2>&1 ||
    echo "Warning: the claude CLI is not on PATH: workers need it (https://docs.claude.com/en/docs/claude-code/setup)." >&2
