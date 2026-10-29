## Sub-agents and workflows on the user's Anthropic API key (claude-api-workers)

Installed on {{DATE}} by claude-api-workers ({{REPO_URL}}). The user wants delegated work billed to their Anthropic API key, not to the Claude subscription this session runs on.

{{MODE_RULE}}

If you are yourself a worker or one of its agents (your system prompt says so, or the environment variable `CLAUDE_WORKER` is `1`), ignore this section and use your own tools directly. The script refuses to run inside a worker anyway.

**Stays in the session:** quick reads and searches that take a few tool calls, and anything that needs the app's own tools or connectors. A worker has no claude.ai connectors (Gmail, Drive, Calendar, ...), no artifacts, no task list and no session management.

**How to delegate:**
1. Write a self-contained brief to a file in your scratchpad. The worker sees nothing of your conversation: give the goal, the files, the constraints, what is already ruled out and the expected deliverable. For parallel work, write explicitly "use a workflow (the user asked for it)", because a worker may not call Workflow without that opt-in. Ask the worker to also write its final report, listing the files it changed, to `<scratchpad>/result-<name>.md`.
2. Launch it in the background (`run_in_background: true`) with your {{SHELL_TOOL}} tool:
   `{{RUN_EXAMPLE}}`
   - Give each worker a short, unique name: it is how you find the run again if anything goes wrong. The launcher also prints the run id on stderr when it starts.
   - The JSON's `result` field is the final report: the worker waits for its own workflow to finish, however long it takes (the launcher sets `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`; without it `claude -p` would stop the workflow 10 minutes after the worker's last turn). `total_cost_usd` is what it cost, and `is_error` flags a failure.
   - Permission mode: pass the mode your session runs in. Use `bypassPermissions` only if this session already runs in it; otherwise use `acceptEdits`, where the worker can read and edit files but cannot run shell commands that need approval.
   - Only point a worker at folders the user trusts: it loads that folder's Claude Code settings and hooks, and runs with the key in its environment.
{{PLATFORM_NOTES}}
3. Check the worker's work (files, diff, result) before you say it is done. Never run two workers on the same files at the same time.

**When a worker fails or is cut off.** A long worker holds context you cannot rebuild cheaply, so don't relaunch it from scratch and don't redo its work yourself. This applies when the launcher prints `run <id> failed (<reason>): ...` on stderr, when the exit code is not 0, when `is_error` is true or the output has no result, and when your own session was restarted or compacted while a worker was running.
1. Get the recovery report: `{{RECOVER_CMD}} <name>` (`last` is the latest run; `{{RUNS_CMD}}` lists them all with their state). It is also saved as `report.md` in the run folder. It gives the reason with what to do next, the brief, the worker's task list, its workflows with their unfinished agents, the files it changed (sub-agents included), its last messages and tool calls, the git changes since it started, and stderr.
2. Act on the reason:
   - `credit` or `auth`: tell the user (add credit, or store a valid key with `{{SETKEY_CMD}}` in their terminal), and wait for them.
   - `rate_limit`, `overloaded`, `server`, `network`, `interrupted`, `killed`, `bg_timeout`: continue right away. If the same error comes back, wait a few minutes.
   - `max_turns` or `budget`: continue with a higher limit if the user agrees.
   - `request` or `unknown`: read the detail and stderr in the report before deciding.
   - State `running`: it is still working, wait. State `orphaned`: claude still runs without its launcher and may still edit files, so wait for it to stop.
3. Continue the same worker, in the background like the first launch: `{{RESUME_CMD}} <name>`. It resumes the worker's own conversation (`claude --resume`) with its whole context, the same model, folder, options and output file, and tells it what happened so it checks the files and finishes only what is left. Add {{PROMPT_OPT}} to give it other instructions. Then check its work as in step 3 above.

Do not fall back to your own sub-agents without the user's OK.

**Models:** the model you pass is the worker's, and its workflow agents inherit it unless your brief says otherwise. Use sonnet by default and haiku for mechanical work, unless the user has set other model preferences. Add `-Fast` (Windows) or `--fast` (macOS/Linux) to ask for fast mode with opus. It is used when the key's organization has access, and otherwise the worker runs at standard speed without failing.

**Launcher exit codes:** 2 means the key is missing, invalid or unreadable, or the input is wrong (tell the user to run `{{SETKEY_CMD}}` in their terminal, hidden prompt, if it is the key); 3 means the script was called from inside a worker; 127 means `claude` is not on PATH. Any other code is claude's own: see the section above.

**Key safety:** never read the key store, and never decrypt or print the key. `{{STATUS_CMD}}` shows it masked if you need to check it. If the user pastes a key into the chat, do not reuse it; suggest they revoke it.
