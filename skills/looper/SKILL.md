---
name: looper
description: Runs pre-publish deployment verification for a packer/<name> plugin in a clean Docker CC container. Invoked when user says "/looper --plugin <name>", "run looper on <name>", "looper verify <name>", or when a skill-test pipeline reaches the deployment verification stage. Also invoked programmatically by other skills/agents that need structured pass/fail results for a plugin.
argument-hint: "--plugin <name> [--image <image>] [--plan a|b|both]"
allowed-tools: ["Bash", "Read"]
---

# Looper — Plugin Deployment Verifier

Looper runs `scripts/run.sh` and presents the structured JSON result to the user.
All test logic lives in the shell script — this skill only handles invocation and presentation.

## Invocation

```bash
# Locate run.sh relative to this skill file
LOOPER_SCRIPT="$(dirname "$(dirname "$(dirname "$SKILL_FILE")")")/scripts/run.sh"
```

If `$ARGUMENTS` is empty or contains `--help`, print the argument-hint and exit without invoking `run.sh`:
  Usage: /looper --plugin <name> [--image <image>] [--plan a|b|both]

Parse `$ARGUMENTS` for `--plugin`, `--image`, `--plan` flags and pass directly to `run.sh`.
Safety note: `$ARGUMENTS` is passed unquoted to allow flag splitting by the shell. Ensure argument values do not contain spaces (plugin names are single tokens; image names are registry paths without spaces). If in doubt, parse flags explicitly into named variables before passing.

```bash
# $SKILL_FILE is injected by CC plugin harness at invocation time
RESULT_JSON=$(bash "$LOOPER_SCRIPT" $ARGUMENTS)
# stderr streams to the user in real time; stdout is captured as RESULT_JSON
```

`run.sh` writes structured JSON to **stdout** and human-readable progress to **stderr**.
Capture stdout as `RESULT_JSON`; let stderr stream to the user in real time.
Note: do **not** use `2>&1` — merging stderr into stdout corrupts the JSON output.

## Output contract (for callers)

`run.sh` exits `0` (all pass → `overall: "pass"`), `1` (test failure → `overall: "fail"`), or `2` (environment error → no `overall` field; JSON is `{"error":...}` or `{"skipped":true,...}`).
stdout is always valid JSON matching this schema:

```json
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

```bash
# Replace "news-digest" with the actual plugin name (value of $PLUGIN_NAME)
RESULT=$(bash "$LOOPER_SCRIPT" --plugin news-digest 2>/dev/null)
OVERALL=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['overall'])")
```

## Presentation (interactive)

Looper typically takes **2–8 minutes** depending on Docker image pull status and eval suite size.
Inform the user before invoking if they have not run it recently (first pull can be 5–10 min).

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

On exit 2 (environment error), present a degraded summary instead:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔁 Looper — <plugin>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Environment error — tests did not run.
  Reason: <error message or "docker unavailable">
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

On FAIL, append root-cause guidance:
- T0 fail → plugin.json schema invalid or required fields missing; fix manifest and retry
- Install missing → check SKILL.md dependencies
- CC start failed → check image availability
- T2b fail → Plan B install sequence failed; review B-step logs in the report file
- Trigger 0% → description not converging, revisit eval stage
- Eval suite fail → behavior differs in clean env vs host
- For full details on any failure, open the report file shown above.
