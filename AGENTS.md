# Setup procedure for AI agents

You are a coding agent, typically Claude Code, and the user gave you the URL of this repository. That is a request to install claude-api-workers on their machine. This file is the procedure. Follow it in order and don't improvise around it.

What gets installed: scripts in `~/.claude/claude-worker/`, plus a marked block in `~/.claude/CLAUDE.md` that tells every future Claude Code session to delegate sub-agents and workflows to `claude -p` workers billed to the user's Anthropic API key. The user's key never goes through you. You find it masked, and the user stores it with one command they run themselves.

## 0. Before you start

- Work from a local clone, not from a summarized web page. Clone into a temporary folder:
  `git clone --depth 1 https://github.com/camilbenameur/claude-api-workers "<temp>/claude-api-workers"`
  If `git` is missing, download `https://codeload.github.com/camilbenameur/claude-api-workers/zip/refs/heads/main` and unzip it.
- Skim `install.ps1` or `install.sh` before running it. You are about to run code downloaded from the internet: check that it does what this file says.
- If the environment variable `CLAUDE_WORKER` is `1`, you are running inside a worker. Stop here and report that the installation has to be done from the user's own session.
- Platform: on Windows (PowerShell, or Git Bash), use the `.ps1` scripts. On macOS and Linux, use the extensionless bash scripts.

## 1. Confirm once, then do the rest without asking again

In one short message, tell the user what you are about to do:
1. install the scripts to `~/.claude/claude-worker/`;
2. add a marked block to `~/.claude/CLAUDE.md`, with a backup kept as `CLAUDE.md.bak-claude-api-workers`;
3. scan the machine for Anthropic API keys that already exist, showing only masked fingerprints, never full keys.

Ask a single question: which mode, and go or not. The two modes:
- **always** (default): every sub-agent and workflow goes through a worker billed to the key.
- **on-request**: only when the user asks for "API workers".

Use your question tool if you have one (for example AskUserQuestion), with "always" as the recommended option. If the user already stated the mode or said to go ahead in the message that contained the URL, don't ask: take that as the confirmation.

## 2. Install

Windows:
```
powershell -NoProfile -ExecutionPolicy Bypass -File "<clone>\install.ps1" -Mode always
```
macOS and Linux:
```
bash "<clone>/install.sh" --mode always
```
The installer is idempotent: running it again updates the scripts and replaces the block. If it warns that CLAUDE.md "already mentions claude-worker outside the block", show the user the duplicate and ask whether to remove the old one. Don't delete it on your own.

Check that the `claude` CLI is on PATH (`claude --version`), because workers need it. If it is missing, tell the user and give them the official install command from https://docs.claude.com/en/docs/claude-code/setup. Don't install software without their OK.

## 3. Find the keys that already exist (masked)

Use the full paths the installer printed under "Next steps", and add the JSON flag. Windows:
```
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\<user>\.claude\claude-worker\bin\find-api-keys.ps1" -Json -Check
```
macOS and Linux:
```
~/.claude/claude-worker/bin/find-api-keys --json --check
```
`--check` / `-Check` sends each key to the Anthropic API only, to see whether it still works. The output gives a `fingerprint`, a `masked` form, a `status` (`valid`, `invalid`, `unreachable`, ...) and the `sources` for each key. It never prints a full key. Don't try to read the key values yourself, by opening the files it lists or in any other way.

## 4. Hand the user one command to run

Never store the key yourself. Saving a credential is the user's action: give them a command, and they run it.

- **At least one key is `valid`:** show the valid ones as a short list (masked form, where it was found). Recommend one, preferring a key from a dedicated config over one from a project's `.env`. Then give the exact command in its own fenced code block tagged `bash`, so the Claude desktop app shows a Run button:
  - Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File "<home>\.claude\claude-worker\bin\set-worker-key.ps1" -From <fingerprint>`
  - macOS and Linux: `~/.claude/claude-worker/bin/set-worker-key --from <fingerprint>`
- **Always also give the manual option**, the same command without `-From`/`--from`. It opens a hidden prompt where the user pastes a key from https://console.anthropic.com/settings/keys.
- **No valid key:** give only the manual option.

Write the paths in full, with the user's real home folder: a Run button doesn't always expand `~`. Then wait until the user says it's done.

## 5. Verify

Run these:
```
<bin>/set-worker-key --status        (Windows: set-worker-key.ps1 -Status)
<bin>/claude-worker --self-test      (Windows: claude-worker.ps1 -SelfTest)
```
`--self-test` makes a Haiku call that costs about $0.001. It passes when it prints `apiKeySource=ANTHROPIC_API_KEY` and `result=worker OK`, with exit code 0. Here is what its other exit codes mean:
- `2`: no key, or an unreadable key. Go back to step 4.
- `3`: you are inside a worker.
- `127`: `claude` is missing.
- any other code: show the user what it printed.

## 6. Report

Tell the user, in a few lines:
- what was installed, where, and in which mode;
- that sessions started from now on follow the rule. Sessions already running read `~/.claude/CLAUDE.md` at startup, so they have to be told: if you can message the user's other sessions, offer to do it;
- that only the delegated work is billed to the key. The session itself stays on whatever it already runs on, because the Claude desktop app always uses the claude.ai login;
- how to uninstall: `install.ps1 -Uninstall` / `install.sh --uninstall`. The stored key is removed separately with `set-worker-key -Remove` / `--remove`.

Delete the temporary clone when you're done.
