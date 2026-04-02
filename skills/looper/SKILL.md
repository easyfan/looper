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

Parse `$ARGUMENTS` for `--plugin`, `--image`, `--plan` flags and pass directly to `run.sh`.

```bash
bash "$LOOPER_SCRIPT" $ARGUMENTS 2>&1
```

`run.sh` writes structured JSON to **stdout** and human-readable progress to **stderr**.
Capture stdout as `RESULT_JSON`; let stderr stream to the user in real time.

## Output contract (for callers)

`run.sh` exits `0` (all pass), `1` (test failure), or `2` (environment error).
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
  }
}
```

On environment error (exit 2), stdout is `{"error": "<message>"}` or `{"skipped": true, "reason": "docker unavailable"}`.

## Programmatic usage (for other skills/agents)

```bash
RESULT=$(bash "$LOOPER_SCRIPT" --plugin news-digest 2>/dev/null)
OVERALL=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['overall'])")
```

## Presentation (interactive)

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
Report:  <report_file>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

On FAIL, append root-cause guidance:
- Trigger 0% → description not converging, revisit eval stage
- Install missing → check SKILL.md dependencies
- CC start failed → check image availability
- Eval suite fail → behavior differs in clean env vs host
