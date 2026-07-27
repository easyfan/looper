#!/usr/bin/env python3
"""Looper T5: run evals.json inside clean CC container."""
import json, os, subprocess, sys

def run_claude(prompt, timeout=480, cwd=None):
    try:
        r = subprocess.run(
            ['claude', '--dangerously-skip-permissions', '-p', prompt],
            capture_output=True, text=True, timeout=timeout, cwd=cwd
        )
        return (r.stdout + r.stderr).strip(), True, r.returncode
    except subprocess.TimeoutExpired:
        return 'TIMEOUT', False, None
    except Exception as e:
        return str(e), False, None

def excerpt(text, limit=8000):
    if len(text) <= limit:
        return text
    half = limit // 2
    return text[:half] + '\n...[truncated]...\n' + text[-half:]

def snapshot(root):
    snap = {}
    for dirpath, _, names in os.walk(root):
        for n in names:
            p = os.path.join(dirpath, n)
            try:
                snap[p] = os.path.getmtime(p)
            except OSError:
                pass
    return snap

def files_summary(root, before, cap=14000):
    # List files created or modified since `before`, with content excerpts,
    # so the judge can verify filesystem-effect assertions.
    lines, used, count = [], 0, 0
    for dirpath, _, names in os.walk(root):
        for n in sorted(names):
            p = os.path.join(dirpath, n)
            try:
                mtime = os.path.getmtime(p)
            except OSError:
                continue
            if before.get(p) == mtime:
                continue
            count += 1
            rel = os.path.relpath(p, root)
            try:
                with open(p, errors='replace') as f:
                    content = f.read(4000)
            except OSError:
                content = '<unreadable>'
            entry = f'--- {rel} ---\n{content}\n'
            if used + len(entry) > cap:
                lines.append(f'--- {rel} --- (content omitted, size cap)')
                continue
            lines.append(entry)
            used += len(entry)
    return ('\n'.join(lines) if lines else '(no files created or modified)'), count

def grade(assertion, output, fsummary):
    prompt = (
        'You are grading one assertion against an agent reply and the files the '
        'agent created or modified in its working directory. '
        'Answer ONLY with YES or NO.\n\n'
        f'Assertion: {assertion}\n\n'
        f'Files created/modified during the run:\n{fsummary}\n\n'
        f'Agent reply:\n{excerpt(output)}'
    )
    # Relay backends intermittently return empty output; retry once so a
    # judge-side blip does not register as a false assertion failure.
    for _ in range(2):
        result, ok, _rc = run_claude(prompt, timeout=90)
        if ok and result.strip():
            return 'YES' in result.upper().split()
    return False

def main():
    evals_path = sys.argv[1] if len(sys.argv) > 1 else 'evals.json'
    work_dir   = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()
    with open(evals_path) as f:
        data = json.load(f)
    cases = data.get('evals', [])
    skill = data.get('skill_name', '?')
    print(f'[T5] {skill} — {len(cases)} eval cases', flush=True)
    passed = 0
    for ev in cases:
        eid, prompt, asserts, files = (
            ev.get('id','?'), ev.get('prompt',''),
            ev.get('assertions',[]), ev.get('files',[])
        )
        # Isolated per-case dir: files written by one case must not leak into
        # the next case's filesystem assertions.
        case_dir = os.path.join(work_dir, f'case_{eid}')
        os.makedirs(case_dir, exist_ok=True)
        for fspec in files:
            p = os.path.join(case_dir, fspec['path'])
            os.makedirs(os.path.dirname(p) or case_dir, exist_ok=True)
            open(p, 'w').write(fspec['content'])
        before = snapshot(case_dir)
        print(f'  [{eid}] {prompt[:60]}', flush=True)
        output, agent_ok, rc = run_claude(prompt, cwd=case_dir)
        fsummary, nchanged = files_summary(case_dir, before)
        # Relay quirk: the model may end on tool use with an empty final text,
        # so `claude -p` prints nothing even though the agent did real work.
        # A timed-out or empty call is retried once even when files changed —
        # otherwise the bare 'TIMEOUT' string is graded as the agent reply and
        # every reply-dependent assertion fails regardless of the files. The
        # retry runs against the same case dir, so files from the first
        # attempt remain part of the evidence.
        if not agent_ok or not output.strip():
            print(f'    (empty/failed agent reply (rc={rc}) — retrying once)', flush=True)
            output, agent_ok, rc = run_claude(prompt, cwd=case_dir)
            fsummary, nchanged = files_summary(case_dir, before)
        # Diagnostic line: distinguishes "agent call failed" from "agent ran but
        # behaved differently" when reading reports after the fact.
        status = output if output in ('TIMEOUT',) or not agent_ok else f'{len(output)} chars'
        print(f'    (agent reply: {status}; changed files: {nchanged}; rc={rc})', flush=True)
        if output == 'TIMEOUT' and nchanged > 0:
            # Grade the files honestly instead of passing the bare sentinel
            # string off as a reply; reply-dependent assertions still fail.
            output = ('(agent process timed out before printing a reply; the '
                      'files listed above are the evidence of what it completed)')
        if (not agent_ok or not output.strip()) and nchanged == 0:
            # Nothing to grade: judging would waste credits, and negative
            # assertions would vacuously pass against empty output.
            print('    (agent reply still empty/failed with no file changes — case marked fail without judging)', flush=True)
            results = [False] * len(asserts)
        else:
            results = [grade(a if isinstance(a, str) else a.get('text', str(a)), output, fsummary) for a in asserts]
        if all(results):
            passed += 1
        for a, r in zip(asserts, results):
            label = a if isinstance(a, str) else a.get('text', str(a))
            print(f'    {"✅" if r else "❌"} {label[:80]}', flush=True)
    total = len(cases)
    print(f'EVAL_SUITE_RESULT:{{"passed":{passed},"total":{total}}}', flush=True)
    sys.exit(0 if passed == total else 1)

if __name__ == '__main__':
    main()
