# Shared helpers for claude-worker, set-worker-key and find-api-keys (macOS/Linux).
# Source it: . "$here/claude-worker-lib.sh". Works with bash 3.2 (macOS default) and later.

# Key store: one file, mode 600. CLAUDE_WORKER_HOME overrides the folder.
# CLAUDE_WORKER_KEY_HELPER, if set, is a command that prints the key on stdout instead
# (e.g. 'security find-generic-password -s claude-worker -w' for the macOS Keychain).
cw_home() {
    if [ -n "${CLAUDE_WORKER_HOME:-}" ]; then printf '%s' "$CLAUDE_WORKER_HOME"
    else printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/claude-worker"; fi
}

cw_key_file() { printf '%s/key' "$(cw_home)"; }

# Prints the key. Returns 1 when none is stored, 2 when it cannot be read.
cw_read_key() {
    if [ -n "${CLAUDE_WORKER_KEY_HELPER:-}" ]; then
        sh -c "$CLAUDE_WORKER_KEY_HELPER" 2>/dev/null | head -n 1 | tr -d '\r\n'
        return 0
    fi
    _f=$(cw_key_file)
    [ -f "$_f" ] || return 1
    [ -r "$_f" ] || return 2
    head -n 1 "$_f" | tr -d '\r\n'
}

cw_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-64
    else shasum -a 256 | cut -c1-64; fi
}

# First 12 hex chars of SHA-256: identifies a key without revealing it
cw_fingerprint() { printf '%s' "$1" | cw_sha256 | cut -c1-12; }

cw_mask() {
    _k=$1; _n=${#_k}
    if [ "$_n" -le 17 ]; then printf '***'; else printf '%s...%s' "${_k:0:13}" "${_k:$((_n - 4))}"; fi
}

# valid | invalid (401/403) | error-<code> | unreachable. Free call: lists one model.
# The key goes to curl through stdin (-K -), never on its command line.
cw_check_key() {
    command -v curl >/dev/null 2>&1 || { echo unreachable; return 0; }
    _base=${CLAUDE_WORKER_BASE_URL:-https://api.anthropic.com}
    _base=${_base%/}
    _k=${1//\\/\\\\}; _k=${_k//\"/\\\"}
    _code=$(printf 'header = "x-api-key: %s"\n' "$_k" |
        curl -s -o /dev/null -w '%{http_code}' --max-time 20 -K - \
            -H 'anthropic-version: 2023-06-01' "$_base/v1/models?limit=1" 2>/dev/null)
    case $_code in
        200) echo valid ;;
        401 | 403) echo invalid ;;
        '' | 000) echo unreachable ;;
        *) echo "error-$_code" ;;
    esac
}

CW_KEY_PATTERN='sk-ant-api[0-9][0-9]-[A-Za-z0-9_-]{20,}'

# Variables starting with these prefixes are removed before a worker starts, except the ones
# listed in CW_KEEP_ENV and in the user's CLAUDE_WORKER_KEEP_ENV (comma-separated names).
CW_KEEP_ENV='CLAUDE_CODE_GIT_BASH_PATH'
cw_should_drop() {
    case $1 in CLAUDE_CODE_* | CLAUDE_AGENT_SDK_* | ANTHROPIC_* | CLAUDECODE | CLAUDE_PID) ;; *) return 1 ;; esac
    case ",$CW_KEEP_ENV,${CLAUDE_WORKER_KEEP_ENV:-}," in *",$1,"*) return 1 ;; esac
    return 0
}
