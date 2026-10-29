## Sub-agents and workflows on the user's Anthropic API key (claude-api-workers)

Installed on {{DATE}} by claude-api-workers ({{REPO_URL}}). The user wants delegated work billed to their Anthropic API key, not to the Claude subscription this session runs on.

{{MODE_RULE}}

If you are yourself a worker or one of its agents (your system prompt says so, or the environment variable `CLAUDE_WORKER` is `1`), ignore this section and use your own tools directly. The script refuses to run inside a worker anyway.

**Stays in the session:** quick reads and searches that take a few tool calls, and anything that needs the app's own tools or connectors. A worker has no claude.ai connectors (Gmail, Drive, Calendar, ...), no artifacts, no task list and no session management.

**How to delegate:**
1. Write a self-contained brief to a file in your scratchpad. The worker sees nothing of your conversation: give the goal, the files, the constraints, what is already ruled out and the expected deliverable. For parallel work, write explicitly "use a workflow (the user asked for it)", because a worker may not call Workflow without that opt-in. Ask the worker to also write its final report, listing the files it changed, to `<scratchpad>/result-<name>.md`.
2. Launch it in the background (`run_in_background: true`) with your {{SHELL_TOOL}} tool:
   `{{RUN_EXAMPLE}}`
   - The JSON's `result` field is the final report: the worker waits for its own workflow to finish. `total_cost_usd` is what it cost, and `is_error` flags a failure.
   - Permission mode: pass the mode your session runs in. Use `bypassPermissions` only if this session already runs in it; otherwise use `acceptEdits`, where the worker can read and edit files but cannot run shell commands that need approval.
   - Only point a worker at folders the user trusts: it loads that folder's Claude Code settings and hooks, and runs with the key in its environment.
{{PLATFORM_NOTES}}
3. Check the worker's work (files, diff, result) before you say it is done. If the process failed or was killed, read `result-<name>.md` and the touched files before relaunching. Never run two workers on the same files at the same time.

**Models:** the model you pass is the worker's, and its workflow agents inherit it unless your brief says otherwise. Use sonnet by default and haiku for mechanical work, unless the user has set other model preferences.

**Failures:** exit code 2 means the key is missing, invalid or unreadable; 3 means the script was called from inside a worker; 127 means `claude` is not on PATH. On exit code 2, or on a 401, 403 or credit error in the output, tell the user to run `{{SETKEY_CMD}}` in their terminal (hidden prompt), then wait. Do not fall back to your own sub-agents without the user's OK.

**Key safety:** never read the key store, and never decrypt or print the key. `{{STATUS_CMD}}` shows it masked if you need to check it. If the user pastes a key into the chat, do not reuse it; suggest they revoke it.
