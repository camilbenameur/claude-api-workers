#!/usr/bin/env python3
"""Summarise a claude-worker transcript as Markdown (used by claude-worker --recover).

    claude-worker-digest.py <session transcript .jsonl>
    claude-worker-digest.py --outcome <transcript .jsonl>   last API error: "error=... status=... <text>"

Reads the main transcript plus the sub-agent and workflow files Claude Code keeps next to it
(<dir>/<session>/subagents/..., <dir>/<session>/workflows/...). Same sections as the
Windows version in claude-worker-runs.ps1. Python 3.6+, standard library only.
"""
import collections
import glob
import io
import json
import os
import re
import sys

EDIT_TOOLS = ('Edit', 'Write', 'MultiEdit', 'NotebookEdit')


def one_line(text, limit):
    text = ' '.join(str(text).split())
    return text if len(text) <= limit else text[:limit - 3] + '...'


def limit_text(text, limit):
    return text if len(text) <= limit else text[:limit] + '\n[... %d more characters]' % (len(text) - limit)


def tool_summary(name, inp):
    if not isinstance(inp, dict):
        return ''
    if name == 'Workflow':
        m = re.search(r"name:\s*['\"]([^'\"]+)", str(inp.get('script') or ''))
        if m:
            return 'workflow ' + m.group(1)
        if inp.get('name'):
            return 'workflow %s' % inp['name']
        if inp.get('scriptPath'):
            return str(inp['scriptPath'])
    for k in ('command', 'file_path', 'notebook_path', 'pattern', 'description', 'url', 'query', 'subject', 'prompt'):
        if inp.get(k):
            return one_line(inp[k], 160)
    return one_line(json.dumps(inp, ensure_ascii=False), 160)


def lines_of(path):
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            yield line


def parse(line):
    try:
        return json.loads(line)
    except ValueError:
        return None


def contents(entry):
    content = (entry.get('message') or {}).get('content')
    return [c for c in content if isinstance(c, dict)] if isinstance(content, list) else []


def outcome(transcript):
    last = None
    for line in lines_of(transcript):
        if '"type":"assistant"' in line:
            last = line
    if not last or '"isApiErrorMessage":true' not in last:
        return ''
    j = parse(last) or {}
    text = ' '.join(c.get('text', '') for c in contents(j) if c.get('type') == 'text')
    return one_line('error=%s status=%s %s' % (j.get('error', ''), j.get('apiErrorStatus', ''), text), 400)


def digest(transcript):
    texts = collections.deque(maxlen=6)
    calls = collections.deque(maxlen=25)
    files = collections.OrderedDict()
    todos = None
    agents = []

    def add_file(path, tool, who):
        if not path:
            return
        ops = files.setdefault(path, collections.OrderedDict())
        key = '%s (%s)' % (tool, who) if who else tool
        ops[key] = ops.get(key, 0) + 1

    for line in lines_of(transcript):
        if '"type":"assistant"' not in line:
            continue
        j = parse(line)
        if not j or j.get('type') != 'assistant' or j.get('isApiErrorMessage'):
            continue
        ts = j.get('timestamp', '')
        for c in contents(j):
            if c.get('type') == 'text' and str(c.get('text', '')).strip():
                texts.append((ts, c['text']))
            elif c.get('type') == 'tool_use':
                name, inp = c.get('name', ''), c.get('input') or {}
                calls.append((ts, name, tool_summary(name, inp)))
                if name in EDIT_TOOLS:
                    add_file(inp.get('file_path') or inp.get('notebook_path'), name, '')
                if name == 'TodoWrite':
                    todos = inp.get('todos') or []
                if name in ('Agent', 'Task'):
                    agents.append(inp.get('description') or one_line(inp.get('prompt', ''), 80))

    # Sub-agents and workflow agents write their own transcripts next to the session's
    session_dir = os.path.splitext(transcript)[0]
    sub_dir = os.path.join(session_dir, 'subagents')
    for f in sorted(glob.glob(os.path.join(sub_dir, '**', '*.jsonl'), recursive=True)):
        if os.path.basename(f) == 'journal.jsonl':
            continue
        for line in lines_of(f):
            if '"tool_use"' not in line or not re.search(r'"name":"(Edit|Write|MultiEdit|NotebookEdit)"', line):
                continue
            j = parse(line)
            if not j or j.get('type') != 'assistant':
                continue
            for c in contents(j):
                if c.get('type') == 'tool_use' and c.get('name') in EDIT_TOOLS:
                    inp = c.get('input') or {}
                    add_file(inp.get('file_path') or inp.get('notebook_path'), c['name'], 'sub-agent')

    # Workflows: <session>/workflows/<runId>.json and <session>/subagents/workflows/<runId>/journal.jsonl
    wf_json_dir = os.path.join(session_dir, 'workflows')
    wf_agents_dir = os.path.join(sub_dir, 'workflows')
    ids = collections.OrderedDict()
    for f in sorted(glob.glob(os.path.join(wf_json_dir, 'wf_*.json'))):
        ids[os.path.splitext(os.path.basename(f))[0]] = 1
    for d in sorted(glob.glob(os.path.join(wf_agents_dir, 'wf_*'))):
        if os.path.isdir(d):
            ids[os.path.basename(d)] = 1
    wf_lines = []
    for run_id in ids:
        name, status, script, err = '', 'unknown', '', ''
        meta = os.path.join(wf_json_dir, run_id + '.json')
        if os.path.isfile(meta):
            try:
                with open(meta, encoding='utf-8', errors='replace') as f:
                    w = json.load(f)
                name, status = w.get('workflowName') or '', w.get('status') or 'unknown'
                script = w.get('scriptPath') or ''
                err = one_line(w['error'], 200) if w.get('error') else ''
            except (ValueError, OSError):
                pass
        started, done = collections.OrderedDict(), set()
        journal = os.path.join(wf_agents_dir, run_id, 'journal.jsonl')
        if os.path.isfile(journal):
            for line in lines_of(journal):
                e = parse(line) or {}
                if e.get('type') == 'started' and e.get('agentId'):
                    started[e['agentId']] = e.get('label', '')
                elif e.get('type') == 'result' and e.get('agentId'):
                    done.add(e['agentId'])
        unfinished = [started[a] for a in started if a not in done]
        line = '- `%s`' % run_id + (' ' + name if name else '')
        line += ' - status %s, %d/%d agents finished' % (status, len(done), len(started))
        if unfinished:
            line += '; unfinished: ' + ', '.join(unfinished[:15])
            if len(unfinished) > 15:
                line += ', ... (%d in all)' % len(unfinished)
        if err:
            line += '; error: ' + err
        if script:
            line += '; script: ' + script
        wf_lines.append(line)

    out = ['## Progress', '']
    if todos:
        out.append('Task list (last TodoWrite):')
        for t in todos:
            box = {'completed': '[x]', 'in_progress': '[~]'}.get(t.get('status'), '[ ]')
            out.append('- %s %s' % (box, t.get('content', '')))
        out.append('')
    if wf_lines:
        out.append('Workflows started by the worker (a resumed worker can try `resumeFromRunId` with these ids):')
        out.extend(wf_lines)
        out.append('')
    if agents:
        out.append('Sub-agents started with the Agent tool: %d (last ones: %s)' % (len(agents), '; '.join(agents[-8:])))
        out.append('')
    if not (todos or wf_lines or agents):
        out += ['No task list, workflow or sub-agent recorded.', '']

    out += ['## Files the worker changed (from its tool calls)', '']
    if files:
        for n, (path, ops) in enumerate(files.items()):
            if n == 150:
                out.append('- ... and %d more' % (len(files) - 150))
                break
            out.append('- %s - %s' % (path, ', '.join('%s x%d' % kv for kv in ops.items())))
    else:
        out.append('None recorded.')
    out.append('')

    out += ['## Last messages from the worker (oldest first)', '']
    if texts:
        for ts, text in texts:
            out += ['### ' + ts, limit_text(text, 2000), '']
    else:
        out += ['None.', '']

    out += ['## Last tool calls (oldest first)', '']
    out += ['- %s %s: %s' % c for c in calls] if calls else ['None.']
    return '\n'.join(out) + '\n'


def main(argv):
    if len(argv) == 3 and argv[1] == '--outcome':
        sys.stdout.write(outcome(argv[2]) + '\n')
        return 0
    if len(argv) != 2:
        sys.stderr.write(__doc__)
        return 2
    sys.stdout.write(digest(argv[1]))
    return 0


if __name__ == '__main__':
    # UTF-8 and LF whatever the locale or platform (a C locale would turn accents into errors)
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', newline='\n')
    sys.exit(main(sys.argv))
