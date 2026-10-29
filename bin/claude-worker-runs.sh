# Run records and crash recovery for claude-worker (macOS/Linux). Sourced after claude-worker-lib.sh.
# Works with bash 3.2. Same layout as claude-worker-runs.ps1:
#   <worker home>/runs/<id>/run.info    key=value lines (values percent-encoded for %, CR and LF;
#                                       one arg= line per claude option)
#                          /prompt.md   the brief; resume-<n>.md holds the prompt of each later resume
#                          /stderr.log  what claude wrote on stderr
#                          /git-start.txt  `git status --porcelain` when the run started
#                          /report.md   the last recovery report (--recover)
# The worker's conversation is Claude Code's transcript, <config>/projects/<dir>/<session>.jsonl,
# with its sub-agents and workflows under <config>/projects/<dir>/<session>/. The transcript digest
# needs python3 (claude-worker-digest.py); without it the report keeps everything else.

# stderr_offset / transcript_offset: where the current attempt starts in stderr.log and in the
# transcript, so that a resumed attempt is judged on its own output only
CW_RUN_FIELDS='id name session_id cwd model fast out_file status reason detail exit_code attempts started last_start last_start_epoch ended launcher_pid claude_pid git_root git_head stderr_offset transcript_offset'

cw_runs_root() { printf '%s/runs' "$(cw_home)"; }
cw_config_dir() { printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }
cw_now() { date '+%Y-%m-%dT%H:%M:%S%z'; }

cw_enc() { _v=${1//%/%25}; _v=${_v//$'\r'/%0D}; printf '%s' "${_v//$'\n'/%0A}"; }
cw_dec() { _v=${1//%0A/$'\n'}; _v=${_v//%0D/$'\r'}; printf '%s' "${_v//%25/%}"; }

# A random version-4 UUID
cw_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid; return; fi
    if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-F' 'a-f'; return; fi
    _h=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    printf '%s-%s-4%s-%x%s-%s\n' "${_h:0:8}" "${_h:8:4}" "${_h:13:3}" $(((0x${_h:16:1} & 3) | 8)) "${_h:17:3}" "${_h:20:12}"
}

# The current run lives in R_<field> variables, plus R_dir and the R_args array.
cw_run_clear() {
    for _f in $CW_RUN_FIELDS; do printf -v "R_$_f" '%s' ''; done
    R_dir='' R_args=()
}

cw_run_new() {  # $1 name, $2 session id
    cw_run_clear
    _root=$(cw_runs_root)
    mkdir -p "$_root" || return 1
    if [ -n "$1" ]; then _label=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-40)
    elif [ -n "$2" ]; then _label=${2:0:8}
    else _u=$(cw_uuid); _label=${_u:0:8}; fi
    R_id="$(date +%Y%m%d-%H%M%S)-$_label"
    # mkdir without -p fails on an existing folder: two launches in the same second never share one
    while ! mkdir "$_root/$R_id" 2>/dev/null; do
        [ -d "$_root/$R_id" ] || return 1
        _u=$(cw_uuid); R_id="$R_id-${_u:0:4}"
    done
    R_dir="$_root/$R_id"
    R_name=$1 R_session_id=$2 R_attempts=1 R_status=running
    R_started=$(cw_now); R_last_start=$R_started
}

cw_run_save() {
    {
        for _f in $CW_RUN_FIELDS; do _n="R_$_f"; printf '%s=%s\n' "$_f" "$(cw_enc "${!_n}")"; done
        for _a in ${R_args[@]+"${R_args[@]}"}; do printf 'arg=%s\n' "$(cw_enc "$_a")"; done
    } > "$R_dir/run.info.tmp" && mv -f "$R_dir/run.info.tmp" "$R_dir/run.info"
}

cw_run_load() {  # $1 run folder
    [ -f "$1/run.info" ] || return 1
    cw_run_clear
    R_dir=$1
    while IFS= read -r _l || [ -n "$_l" ]; do
        _k=${_l%%=*}; _v=$(cw_dec "${_l#*=}")
        case $_k in
            arg) R_args+=("$_v") ;;
            *) case " $CW_RUN_FIELDS " in *" $_k "*) printf -v "R_$_k" '%s' "$_v" ;; esac ;;
        esac
    done < "$1/run.info"
}

# A run id, a --name (latest run with it), a unique prefix of an id or session id, or "last".
# Loads the run and returns 0, or returns 1.
cw_run_find() {
    _root=$(cw_runs_root); _ref=$1; _hit='' _count=0
    [ -d "$_root" ] && [ -n "$_ref" ] || return 1
    if [ "$_ref" = last ]; then
        for _d in "$_root"/*/; do [ -f "$_d/run.info" ] && _hit=${_d%/}; done
    elif [ -f "$_root/$_ref/run.info" ]; then
        _hit="$_root/$_ref"
    else
        for _d in "$_root"/*/; do
            _d=${_d%/}; [ -f "$_d/run.info" ] || continue
            grep -qxF "name=$(cw_enc "$_ref")" "$_d/run.info" && _hit=$_d
        done
        if [ -z "$_hit" ] && [ ${#_ref} -ge 6 ]; then
            for _d in "$_root"/*/; do
                _d=${_d%/}; [ -f "$_d/run.info" ] || continue
                case ${_d##*/} in "$_ref"*) _hit=$_d; _count=$((_count + 1)); continue ;; esac
                if grep -q "^session_id=$_ref" "$_d/run.info"; then _hit=$_d; _count=$((_count + 1)); fi
            done
            [ "$_count" -eq 1 ] || _hit=''
        fi
    fi
    [ -n "$_hit" ] && cw_run_load "$_hit"
}

# ps etime ([[dd-]hh:]mm:ss) in seconds
cw_etime_seconds() {
    _e=$(printf '%s' "$1" | tr -d ' '); _d=0
    case $_e in *-*) _d=${_e%%-*}; _e=${_e#*-} ;; esac
    _s=0
    for _p in $(printf '%s' "$_e" | tr ':' ' '); do _s=$((_s * 60 + 10#$_p)); done
    echo $((_d * 86400 + _s))
}

# $1 PID, $2 epoch when the run started (optional). A PID recycled by a process started after
# the run is not ours. Without a usable ps (Git Bash), kill -0 alone decides.
cw_pid_alive() {
    case $1 in '' | *[!0-9]*) return 1 ;; esac
    kill -0 "$1" 2>/dev/null || return 1
    case ${2:-} in '' | *[!0-9]*) return 0 ;; esac
    _et=$(ps -o etime= -p "$1" 2>/dev/null) || return 0
    [ -n "$_et" ] || return 0
    _age=$(cw_etime_seconds "$_et")
    [ $(($(date +%s) - _age)) -le $(($2 + 5)) ]
}

# The JSON result line of an output file, or nothing
cw_result_line() { [ -n "$1" ] && [ -f "$1" ] && grep '^[[:space:]]*{.*"type":"result"' "$1" | tail -n 1; }

# running | orphaned (launcher gone, claude still running) | interrupted | succeeded | failed
cw_run_state() {
    if [ "$R_status" != running ]; then printf '%s' "$R_status"
    elif cw_pid_alive "$R_launcher_pid" "$R_last_start_epoch"; then printf running
    elif cw_pid_alive "$R_claude_pid" "$R_last_start_epoch"; then printf orphaned
    else
        # Launcher and claude are gone. If claude still finished cleanly, its result is in the output file.
        _line=$(cw_result_line "$R_out_file")
        case $_line in *'"is_error":false'*)
            # run.info was last written right after claude started
            if [ "$R_out_file" -nt "$R_dir/run.info" ]; then
                R_status=succeeded R_detail='the launcher was lost; the result was read from the output file' R_ended=$(cw_now)
                cw_run_save; printf succeeded; return
            fi ;;
        esac
        printf interrupted
    fi
}

# <run>/lock is a folder holding the launcher's PID while it works on the run. A lock whose
# launcher is dead is stale and taken over.
cw_run_lock() {
    _lk="$R_dir/lock"
    if ! mkdir "$_lk" 2>/dev/null; then
        _holder=$(cat "$_lk/pid" 2>/dev/null)
        if [ -n "$_holder" ] && cw_pid_alive "$_holder"; then return 1; fi
        rm -rf "$_lk" && mkdir "$_lk" 2>/dev/null || return 1
    fi
    printf '%s' "$$" > "$_lk/pid"
}
cw_run_unlock() { [ -n "${R_dir:-}" ] && [ "$(cat "$R_dir/lock/pid" 2>/dev/null)" = "$$" ] && rm -rf "$R_dir/lock"; }

cw_transcript() {
    [ -n "$R_session_id" ] || return 1
    for _t in "$(cw_config_dir)"/projects/*/"$R_session_id.jsonl"; do
        [ -f "$_t" ] && { printf '%s' "$_t"; return 0; }
    done
    return 1
}

cw_python() {
    for _p in python3 python; do
        command -v "$_p" >/dev/null 2>&1 && "$_p" -c 'import sys; sys.exit(sys.version_info < (3, 6))' 2>/dev/null && { printf '%s' "$_p"; return 0; }
    done
    return 1
}

# First "key":"string" value of a JSON line (good enough for the flat fields used here)
cw_json_str() { printf '%s' "$2" | grep -oE "\"$1\":\"([^\"\\\\]|\\\\.)*\"" | head -n 1 | sed "s/^\"$1\":\"//; s/\"\$//"; }
cw_json_num() { printf '%s' "$2" | grep -o "\"$1\":[0-9]*" | head -n 1 | cut -d: -f2; }

cw_failure_reason() {  # $1 facts, $2 exit code, $3 killed
    [ "$3" = 1 ] && { echo killed; return; }
    _t=$1
    while IFS='|' read -r _r _re; do
        printf '%s' "$_t" | grep -Eiq -- "$_re" && { echo "$_r"; return; }
    done <<'RULES'
max_turns|error_max_turns
budget|error_max_budget|max-budget
credit|billing_error|credit balance|insufficient_quota|spend limit|status=402
auth|authentication|invalid api key|invalid x-api-key|permission_error|status=40[13]([^0-9]|$)
rate_limit|rate_limit|status=429
overloaded|overloaded|status=529
network|ECONNREFUSED|ECONNRESET|ETIMEDOUT|ENOTFOUND|EAI_AGAIN|connection (refused|error|reset)|socket hang up|fetch failed|network
server|server_error|status=5[0-9][0-9]|internal server error
request|invalid_request|status=4[0-9][0-9]
bg_timeout|Background tasks still running
RULES
    case $2 in 130 | 137 | 143) echo killed; return ;; esac
    echo unknown
}

# Why the run failed, from what claude left: the --out-file JSON result, the transcript's last
# assistant message (isApiErrorMessage) and stderr. Sets O_failed (0/1), O_reason, O_detail.
cw_run_outcome() {  # $1 exit code, $2 killed (0/1)
    _facts='' _detail='' _is_error=0
    _line=$(cw_result_line "$R_out_file")
    if [ -n "$_line" ]; then
        _facts="subtype=$(cw_json_str subtype "$_line") terminal_reason=$(cw_json_str terminal_reason "$_line") api_error_status=$(cw_json_num api_error_status "$_line")"
        case $_line in *'"is_error":true'*)
            _is_error=1; _detail=$(cw_json_str result "$_line")
            _facts="$_facts $(printf '%s' "$_detail" | tr -s '\r\n\t ' '    ' | cut -c1-400)" ;;
        esac
        # claude reports the session it really used (a resume or fork may change it)
        _s=$(cw_json_str session_id "$_line"); [ -n "$_s" ] && R_session_id=$_s
    fi
    # Only what the current attempt wrote: a resume appends to the transcript and to stderr.log
    if _t=$(cw_transcript); then
        _last=$(tail -c +$((${R_transcript_offset:-0} + 1)) "$_t" | grep '"type":"assistant"' | tail -n 1)
        case $_last in *'"isApiErrorMessage":true'*)
            _is_error=1
            if _py=$(cw_python); then _e=$("$_py" "$here/claude-worker-digest.py" --outcome "$_t" "${R_transcript_offset:-0}")
            else _e="error=$(cw_json_str error "$_last") status=$(cw_json_num apiErrorStatus "$_last") $(cw_json_str text "$_last")"; fi
            _facts="$_facts $_e"
            [ -n "$_detail" ] || _detail=$(printf '%s' "$_e" | sed 's/^error=[^ ]* status=[^ ]* //') ;;
        esac
    fi
    if [ -f "$R_dir/stderr.log" ]; then
        _tail=$(tail -c +$((${R_stderr_offset:-0} + 1)) "$R_dir/stderr.log" | grep -v 'connectors are disabled' | grep -v '^[[:space:]]*$' | tail -n 20)
        if [ -n "$_tail" ]; then
            _facts="$_facts $(printf '%s' "$_tail" | tr '\n' ' ')"
            [ -n "$_detail" ] || _detail=$(printf '%s\n' "$_tail" | tail -n 1)
        fi
    fi
    case $_facts in *'Background tasks still running'*) _bg=1 ;; *) _bg=0 ;; esac
    if [ "$1" = 0 ] && [ "$_is_error" = 0 ] && [ "$_bg" = 0 ] && [ "$2" != 1 ]; then
        O_failed=0 O_reason='' O_detail=''
        return
    fi
    O_failed=1
    O_reason=$(cw_failure_reason "$_facts" "$1" "$2")
    [ -n "$_detail" ] || _detail="claude exited with code $1"
    O_detail=$(printf '%s' "$_detail" | tr -s '\r\n\t ' '    ' | cut -c1-300)
}

cw_run_complete() {  # $1 exit code, $2 killed
    cw_run_outcome "$1" "$2"
    if [ "$O_failed" = 1 ]; then R_status=failed; else R_status=succeeded; fi
    R_reason=$O_reason R_detail=$O_detail R_exit_code=$1 R_ended=$(cw_now)
    cw_run_save
}

cw_advice() {  # $1 state
    _setkey="\"$here/set-worker-key\""
    _what=$1; [ "$1" = failed ] && _what=$R_reason
    case $_what in
        succeeded) echo 'The run finished. Its final report is in the output file (`result` field).' ;;
        running) echo "The worker is still running (launcher PID $R_launcher_pid). Wait for it before continuing anything." ;;
        orphaned) echo "Its launcher is gone but claude is still running (PID $R_claude_pid) and may still be editing files. Wait for it to stop, or stop it, before --resume-run (which then needs --force)." ;;
        interrupted) echo 'The launcher stopped without recording an end (session closed, process killed or machine restarted). Continue the run.' ;;
        killed) echo 'The worker was stopped by a signal. Continue the run.' ;;
        credit) echo "The key's credit is exhausted. Ask the user to add credit or to store another key ($_setkey), then continue the run." ;;
        auth) echo "The key was rejected (expired, revoked or invalid). Ask the user to store a valid key ($_setkey), then continue the run." ;;
        rate_limit) echo 'Rate limited by the API. Continue the run in a few minutes.' ;;
        overloaded) echo 'The API was overloaded. Continue the run now; if it fails again, wait a few minutes.' ;;
        server) echo 'The API returned a server error. Continue the run now; if it fails again, wait a few minutes.' ;;
        request) echo 'The API refused the request (for example a prompt or context that is too long): read the detail before continuing.' ;;
        network) echo 'Network problem (connection refused, reset or timed out). Check the connection, then continue the run.' ;;
        max_turns) echo 'The worker reached --max-turns. Continue the run with a higher --max-turns.' ;;
        budget) echo 'The worker reached --max-budget-usd. Continue the run with a higher budget if the user agrees.' ;;
        bg_timeout) echo 'claude stopped background tasks (a workflow) before they finished. Continue the run.' ;;
        *) echo 'Unknown failure: read the last messages and stderr below before deciding.' ;;
    esac
}

cw_limit_file() {  # $1 file, $2 max characters
    _size=$(wc -c < "$1" | tr -d ' ')
    if [ "$_size" -le "$2" ]; then cat "$1"; echo
    else head -c "$2" "$1"; printf '\n[... %s more bytes]\n' $((_size - $2)); fi
}

cw_run_report() {
    _state=$(cw_run_state)
    _status=$_state; [ "$_state" = failed ] && _status="failed ($R_reason): $R_detail"
    _fast=''; [ "$R_fast" = 1 ] && _fast=' (fast mode requested)'
    echo "# Worker run $R_id"
    echo
    echo "- Status: $_status"
    [ -n "$R_name" ] && echo "- Name: $R_name"
    echo "- Session: $R_session_id - model $R_model$_fast - attempts $R_attempts"
    echo "- Folder: $R_cwd"
    echo "- Started: $R_started - last start $R_last_start - ended $R_ended - exit code $R_exit_code"
    [ -n "$R_out_file" ] && echo "- Output file: $R_out_file"
    _t=$(cw_transcript) || _t=''
    if [ -n "$_t" ]; then echo "- Transcript: $_t"
    else echo "- Transcript: none found for this session under $(cw_config_dir)/projects"; fi
    echo "- Run files: $R_dir"
    echo
    echo '## What to do next'
    echo
    cw_advice "$_state"
    if [ "$_state" != succeeded ] && [ "$_state" != running ]; then
        echo
        echo "To continue the same worker with its whole conversation (billed to the key): \`\"$here/claude-worker\" --resume-run $R_id\`, in the background like the first launch. It reuses the model, folder, options and output file; add \`--prompt \"...\"\` to give other instructions. Prefer this to a new worker, which would start without any of this context."
    fi
    echo
    echo '## Brief'
    echo
    if [ -f "$R_dir/prompt.md" ]; then cw_limit_file "$R_dir/prompt.md" 20000; else echo 'Not recorded.'; fi
    echo
    if [ -n "$_t" ]; then
        if _py=$(cw_python); then "$_py" "$here/claude-worker-digest.py" "$_t"
        else echo "(python3 is needed to summarise the transcript: read it directly, it is JSON Lines)"; fi
        echo
    fi
    echo '## Git'
    echo
    if command -v git >/dev/null 2>&1 && _root=$(git -C "$R_cwd" rev-parse --show-toplevel 2>/dev/null); then
        if [ -n "$R_git_head" ]; then
            echo "Commits since the run started (${R_git_head:0:12}):"
            echo '```'; git -C "$_root" log --oneline "$R_git_head..HEAD" 2>/dev/null | head -n 50; echo '```'
            echo "Changes since then (committed or not, \`git diff --stat ${R_git_head:0:12}\`):"
            echo '```'; git -C "$_root" diff --stat "$R_git_head" 2>/dev/null | tail -n 80; echo '```'
        fi
        echo '`git status --porcelain` now:'
        echo '```'; git -C "$_root" status --porcelain 2>/dev/null | head -n 80; echo '```'
        [ -s "$R_dir/git-start.txt" ] && echo "Files already modified before the run started: $R_dir/git-start.txt"
    else
        echo 'Not a git repository.'
    fi
    echo
    echo '## Stderr (last lines)'
    echo
    _tail=''
    [ -f "$R_dir/stderr.log" ] && _tail=$(grep -v '^[[:space:]]*$' "$R_dir/stderr.log" | tail -n 20)
    if [ -n "$_tail" ]; then echo '```'; printf '%s\n' "$_tail"; echo '```'; else echo 'Empty.'; fi
}

cw_resume_prompt() {
    if [ "$R_status" = failed ]; then _why="$R_reason: $R_detail"; else _why=$(cw_run_state); fi
    cat <<EOF
Your previous run stopped before the end ($_why). You still have your whole conversation, but files may have changed since, and any workflow or sub-agent you had started was stopped with you.
First check the current state of the files you were working on (and \`git status\` if this is a git repository). Then finish the original task without redoing work that is already done. If a workflow was unfinished, resume it with resumeFromRunId if the Workflow tool accepts it; otherwise start a new workflow that covers only what is left.
End with the final report the original brief asked for, including the files written by the earlier attempt.
EOF
}
