---
name: looper
description: Runs pre-publish deployment verification for a packer/<name> plugin in a clean Docker CC container. Invoked when user says "/looper --plugin <name>", "run looper on <name>", "looper verify <name>", or when a skill-test pipeline reaches the deployment verification stage. Also invoked programmatically by other skills/agents that need structured pass/fail results for a plugin.
argument-hint: "--plugin <name> [--image <image>] [--plan a|b|both] [--help]"
allowed-tools: ["Bash", "Read"]
---

# Looper — Plugin Deployment Verifier

Looper runs `scripts/run.sh` and presents the structured JSON result to the user.
All test logic lives in the shell script — this skill only handles invocation and presentation.

## Invocation

**Step 1 — help/no-args check (no path computation needed):**

If `$ARGUMENTS` is empty or contains `--help`, print the following and exit immediately without computing any path or invoking `run.sh`. This check must happen before any other processing — even before computing `$LOOPER_SCRIPT`.

  Usage: /looper --plugin <name> [--image <image>] [--plan a|b|both] [--help]

  Options:
    --plugin <name>    Plugin directory name under packer/ (required)
    --image  <image>   Docker image to use (default: cc-runtime-minimal)
    --plan   a|b|both  Test plan: a=Plan A only, b=Plan B only, both=all tests (default: both)
    --help             Show this help and exit

  Examples:
    /looper --plugin news-digest
    /looper --plugin news-digest --plan a
    /looper --plugin news-digest --image cc-runtime-minimal

**Step 2 — resolve script path (only reached when a real invocation is needed):**

```bash
# $SKILL_FILE is injected by the CC plugin harness at invocation time (CC context only —
# private implementation variable, not a standard POSIX or CC public API).
# If not running under CC, this variable will be empty and the derived path will be invalid.
# It resolves to the absolute path of this SKILL.md file.
LOOPER_SCRIPT="$(dirname "$(dirname "$(dirname "$SKILL_FILE")")")/scripts/run.sh"
```

**Step 3 — invoke:**

Parse `$ARGUMENTS` for `--plugin`, `--image`, `--plan` flags and pass directly to `run.sh`.
Safety note: `$ARGUMENTS` is passed unquoted to allow flag splitting by the shell. Ensure argument values do not contain spaces and do not contain shell metacharacters (`;`, `|`, `` ` ``, `$(...)`). Plugin names and image names are plain tokens; they should never need quoting. If any argument value originates from user input, parse flags explicitly into named variables before passing (e.g. `bash "$LOOPER_SCRIPT" --plugin "$PLUGIN" --plan "$PLAN"`).

```bash
# $SKILL_FILE is injected by CC plugin harness at invocation time (CC context only)
# If not running under CC, $SKILL_FILE will be empty and $LOOPER_SCRIPT will be an invalid path
RESULT_JSON=$(bash "$LOOPER_SCRIPT" $ARGUMENTS)
# stdout is captured as RESULT_JSON; stderr is not redirected (progress visible to user)
```

`run.sh` writes structured JSON to **stdout** and human-readable progress to **stderr**.
Capture stdout as `RESULT_JSON`; do not redirect stderr (progress output will reach the user,
though exact streaming behavior depends on the execution environment).
Note: do **not** use `2>&1` — merging stderr into stdout corrupts the JSON output.

## Output contract (for callers)

`run.sh` exits `0` (all pass → `overall: "pass"`), `1` (test failure → `overall: "fail"`), or `2` (environment error → no `overall` field; JSON is `{"error":...}` or `{"skipped":true,...}`).
stdout is always valid JSON matching this schema (annotated with `//` comments for clarity; comments do not appear in actual output):

```jsonc
{
  "plugin": "news-digest",
  "overall": "pass | fail",
  "image": "cc-runtime-minimal",
  "image_strategy": "local-cached",
  "timestamp": "20260403_120000",
  "report_file": "/path/to/looper/reports/20260403_120000_looper_news-digest.md",
  "tests": {
    "T0": { "pass": "pass | fail | skip", "detail": "..." },
    "T1": { "pass": "pass | fail",        "detail": "2.1.90 (Claude Code)" },
    "T2": { "pass": "pass | fail | skip", "detail": "A1:pass A2:pass ..." },
    "T2b":{ "pass": "pass | fail | skip", "detail": "B1:pass B2:pass ..." },
    "T3": { "pass": "pass | fail",        "output_snippet": "..." },
    "T5": { "pass": "pass | fail | skip", "rate": "6/6" }
    // Note: T4 is intentionally absent — T4 (artifact/package build step) was retired
    // and its checks were absorbed into T3 and T5. The numbering gap is preserved for
    // historical traceability.
  }
}
```

On environment error (exit 2), stdout is `{"error": "<message>"}` or `{"skipped": true, "reason": "docker unavailable"}`.

## Programmatic usage (for other skills/agents)

This section is for skills or shell scripts that invoke looper directly via `run.sh`.
`$SKILL_FILE` and `$LOOPER_SCRIPT` are **not** available in the caller's environment —
callers must locate `run.sh` independently (e.g., via a known absolute path, a
`plugin.json`-relative path, or by invoking looper as a CC skill via `/looper`).

```bash
# Locate run.sh: adjust this path to match the caller's repo layout
LOOPER_SCRIPT="/path/to/looper/scripts/run.sh"

# Replace "news-digest" with the actual plugin name
EXIT_CODE=0
RESULT=$(bash "$LOOPER_SCRIPT" --plugin news-digest 2>/dev/null) || EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 2 ]; then
  # Environment error — no 'overall' field in JSON; handle separately
  echo "Looper environment error: $(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error', d.get('reason', 'unknown')))")"
  exit 1
fi

OVERALL=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('overall', 'unknown'))")
```

## Presentation (interactive)

Looper typically takes **2–8 minutes** depending on Docker image pull status and eval suite size. (First pull: 5–10 minutes.)
Inform the user before invoking if the Docker image is not yet cached locally (first pull can be 5–10 minutes).

After `run.sh` completes, present the result as:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔁 Looper — <plugin>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  T0  plugin.json:          ✅/❌/⏭️
  T1  CC availability:      ✅/❌  <version>
  T2  Plan A (A1–A7):       ✅/❌/⏭️  <detail>
  T2b Plan B (B1–B8):       ✅/❌/⏭️  <detail>
  T3  Trigger:              ✅/❌
  T5  Eval suite:           ✅/❌/⏭️  <rate>

Overall: ✅ PASS / ❌ FAIL
Image:   <image> (<image_strategy>)
Report:  <report_file>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

On exit 2 (environment error), the JSON contains either `{"error": "<message>"}` or
`{"skipped": true, "reason": "<message>"}`. Present the appropriate degraded summary:

If `skipped` is true (docker/environment unavailable, tests intentionally skipped):
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔁 Looper — <plugin>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Skipped — environment unavailable.
  Reason: <reason field>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

If `error` is present (unexpected runtime failure):
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔁 Looper — <plugin>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Environment error — tests did not run.
  Error: <error field>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

On FAIL, append root-cause guidance:
- T0 fail → plugin.json schema invalid or required fields missing; fix manifest and retry
- Install missing (T2/T2b) → dependency missing in plugin's install manifest; check SKILL.md dependencies and verify the install step that failed in the report file
- CC start failed → check image availability
- T2b fail → Plan B install sequence failed; open the report file and search for the first B-step marked "fail" to locate the failing step
- Trigger 0% → description not converging, revisit eval stage
- Eval suite fail → behavior differs in clean env vs host
- For full details on any failure, open the report file shown above.
