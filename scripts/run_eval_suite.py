#!/usr/bin/env python3
"""Looper T5: run evals.json inside clean CC container."""
import json, os, subprocess, sys

def run_claude(prompt, timeout=180):
    try:
        r = subprocess.run(
            ['claude', '--dangerously-skip-permissions', '-p', prompt],
            capture_output=True, text=True, timeout=timeout
        )
        return (r.stdout + r.stderr).strip(), True
    except subprocess.TimeoutExpired:
        return 'TIMEOUT', False
    except Exception as e:
        return str(e), False

def grade(assertion, output):
    prompt = (
        "Does the following output satisfy the assertion? "
        "Answer ONLY with YES or NO.\n\n"
        f"Assertion: {assertion}\n\nOutput:\n{output[:2000]}"
    )
    result, ok = run_claude(prompt, timeout=30)
    return ok and 'YES' in result.upper().split()

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
        for fspec in files:
            p = os.path.join(work_dir, fspec['path'])
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, 'w').write(fspec['content'])
        print(f'  [{eid}] {prompt[:60]}', flush=True)
        output, _ = run_claude(prompt)
        results = [grade(a if isinstance(a, str) else a.get('text', str(a)), output) for a in asserts]
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
