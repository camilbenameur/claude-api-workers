# claude-api-workers

> **AI agents:** if the user asked you to install this repository, clone it and follow [AGENTS.md](AGENTS.md) step by step, because a summarized web view of this page loses details. If they only shared the link, ask them what they want first.

This tool runs Claude Code's sub-agents and workflows on your **Anthropic API key**, while your main session stays on your Claude subscription.

Your Claude Code session keeps running on the plan you signed in with. Every time it would spawn sub-agents or a multi-agent workflow, it hands the job to a **worker** instead. A worker is a headless `claude -p` process authenticated with your API key, and it has its own `Task` and `Workflow` tools, so everything it spawns is billed to the key, not to your plan's usage limits.

Useful when:
- you have API credits to spend;
- big workflows eat into your weekly plan limits;
- you use the Claude desktop app, which ignores `ANTHROPIC_API_KEY` and `apiKeyHelper` for its own sessions.

## Install: one sentence in Claude Code

Open a Claude Code session (CLI, desktop app or IDE), paste:

```
Install https://github.com/camilbenameur/claude-api-workers
```

and press Enter. The sentence matters. A careful agent won't change your global config just because a page it read tells it to, so the request has to come from you, and a bare link isn't one. The agent then follows [AGENTS.md](AGENTS.md):
1. It clones the repository, tells you what it is about to change, and asks for one confirmation (mode `always` or `on-request`).
2. It installs the scripts and adds a marked block to `~/.claude/CLAUDE.md`.
3. It scans your machine for Anthropic API keys you already have (environment variables, shell profiles, `.env` files, Claude Code settings, and so on). It shows them **masked** and checks which ones still work.
4. It gives you **one command to run**, with a Run button in the desktop app, that stores the key you picked, or opens a hidden prompt where you paste one.
5. It runs a self-test that costs about $0.001 and confirms the worker authenticates with the key.

The agent never handles your key: it only sees masked fingerprints, and you store the key yourself.

### Manual install

```bash
git clone https://github.com/camilbenameur/claude-api-workers
cd claude-api-workers
./install.sh                     # macOS / Linux   (--mode on-request, --uninstall)
```
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1     # Windows (-Mode on-request, -Uninstall)
```
Then store a key and test:
```bash
~/.claude/claude-worker/bin/set-worker-key            # hidden prompt
~/.claude/claude-worker/bin/claude-worker --self-test
```
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.claude\claude-worker\bin\set-worker-key.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.claude\claude-worker\bin\claude-worker.ps1" -SelfTest
```

## What gets installed

| Path | Role |
|---|---|
| `~/.claude/claude-worker/bin/claude-worker[.ps1]` | Runs a worker: loads the key, removes the variables the parent session passes down, runs `claude -p`. |
| `~/.claude/claude-worker/bin/set-worker-key[.ps1]` | Stores the key (hidden prompt, or `--from <fingerprint>`), plus `--status` and `--remove`. |
| `~/.claude/claude-worker/bin/find-api-keys[.ps1]` | Lists the Anthropic keys already on the machine, masked. `--check` tests them, `--json` is for agents. |
| Block in `~/.claude/CLAUDE.md` | The rule every session reads: when and how to delegate to a worker, and what to do on failure. |

**Key storage:**
- **Windows:** `%LOCALAPPDATA%\claude-worker\key.dat`, encrypted with DPAPI, so only your Windows account can decrypt it.
- **macOS and Linux:** `~/.config/claude-worker/key`, a mode-600 file. If you'd rather keep the key in a secret manager, set `CLAUDE_WORKER_KEY_HELPER` to a command that prints it, for example `security find-generic-password -s claude-worker -w` or `op read op://vault/anthropic/key`.

## How a session uses it

The installed rule tells the agent to write a self-contained brief and launch a worker in the background:

```bash
~/.claude/claude-worker/bin/claude-worker --prompt-file brief.md --model sonnet \
  --cwd ~/my-project --out-file out.json --permission-mode acceptEdits --output-format json
```

- **Workflows:** if the brief says "use a workflow", the worker runs one and waits for it to finish. All of its agents are billed to the key.
- **Fast mode:** `--fast` (`-Fast` on Windows) sends Claude Code's opt-in (`{"fastMode": true}` through `--settings`). Whether fast mode is actually available is decided by the API for your organization. Without access, the worker runs at standard speed. To see which applies to you, run `claude-worker --self-test --model opus --fast`: it prints `fast_mode=on`, or `off` with the reason.
- **Result:** `out.json` holds the final report in `result`, plus `total_cost_usd`.
- **Other options:** any option the wrapper doesn't know is passed to `claude` as is.

Exit codes: claude's own code, or `2` for a key or input problem, `3` when called from inside a worker, `127` when `claude` is not on PATH.

## Safety model

- **The scripts never print the key or put it on a command line.**
  - It is decrypted only in the worker process and handed to `claude` through `ANTHROPIC_API_KEY`.
  - The online check sends it through stdin or a request header.
  - The variable is visible to what runs inside the worker (its shell commands, hooks and MCP servers). A worker allowed to run commands, and especially one in `bypassPermissions` mode, could therefore read it.
  - Point workers only at folders you trust: a worker also loads that folder's `.claude/settings.json`.
- **Key detection is read-only and masked.**
  - `find-api-keys` reads environment variables, known config files, and `.env`-style files under your home folder. It skips `node_modules`, `.git`, caches and virtualenvs, stays on one filesystem, and doesn't follow symlinks.
  - On macOS it skips `~/Documents`, `~/Desktop` and `~/Downloads` unless you pass them with `--root`, because walking them triggers privacy prompts.
  - It prints a fingerprint (the first 12 hex characters of the SHA-256), the first 13 and last 4 characters, and where it found each key.
  - Nothing leaves the machine except with `--check`, which calls `GET /v1/models` on the Anthropic API.
- **Storing a key is always the user's action.** Agents only hand out the command.
- **No silent fallback.**
  - A missing or unreadable key stops the worker with exit code 2. Otherwise `claude` would quietly fall back to your subscription login.
  - The worker also drops the `CLAUDE_CODE_*` and `ANTHROPIC_*` variables the Claude app passes to child processes, which would otherwise take precedence over the key. Two exceptions are kept: `CLAUDE_CODE_GIT_BASH_PATH`, and any names you list in `CLAUDE_WORKER_KEEP_ENV` (comma-separated).
  - To send workers through a gateway, set `CLAUDE_WORKER_BASE_URL`.
- **No recursion.** Workers get `CLAUDE_WORKER=1` and an appended system prompt. The script refuses to run inside a worker, even when the worker's own agents read the same CLAUDE.md rule.
- **No surprise permissions.** The rule tells the session to give the worker its own permission mode (`acceptEdits` unless the session already runs in `bypassPermissions`).

## Limits

- **Only delegated work is billed to the key.** The session itself stays on its own login. In particular, the desktop app always uses claude.ai.
- **Workers have no claude.ai connectors** (Gmail, Drive, Calendar, ...) and none of the app's own tools (artifacts, task list, session management). That work stays in the session.
- **Running sessions don't pick up the rule.** Sessions read `~/.claude/CLAUDE.md` when they start, so sessions that were already running have to be told.
- **Prompt caching is automatic.** Claude Code caches the system prompt and context on its own (a test worker read about 20k of its tokens from cache), so there is nothing to configure.
- **Tested so far:**
  - end to end on Windows 11: a fresh Claude Code session, given only "Install <url> in always mode, don't ask again" in a sandboxed profile, installed everything, listed the keys masked (a valid one, plus a planted revoked one flagged invalid), stored nothing itself, and handed back the `-From <fingerprint>` command;
  - Windows 11 with Windows PowerShell 5.1, against the real API;
  - the bash scripts under Ubuntu (WSL) and Git Bash, with a stub `claude` (`tests/`).
  - macOS should work (bash 3.2 compatible, `shasum` fallback) but hasn't been tested yet. Reports are welcome.

## Uninstall

The installer copies itself to `~/.claude/claude-worker/`, so you don't need the clone:

```bash
~/.claude/claude-worker/bin/set-worker-key --remove     # optional: delete the stored key first
bash ~/.claude/claude-worker/install.sh --uninstall
```
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.claude\claude-worker\install.ps1" -Uninstall
```
Uninstalling removes only the files it installed and its own block in `CLAUDE.md`. The `CLAUDE.md` as it was before the first install is kept as `CLAUDE.md.bak-claude-api-workers`.

## Tests

```bash
bash tests/test.sh                                                   # bash scripts, stub claude, temp HOME
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test.ps1   # Windows scripts, same idea
```

## License

MIT
