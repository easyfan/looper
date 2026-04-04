# looper

Deploy-time verification for Claude Code plugins — runs installation integrity,
trigger accuracy, and behavioral eval suite (T5) tests inside a clean Docker CC container.
Used as Stage 5 of the skill-test pipeline.

## Install

### Option A — Claude Code plugin marketplace

```
/plugin marketplace update looper
/plugin install looper@looper
```

> First time? Add the marketplace first:
> ```
> /plugin marketplace add easyfan/looper
> /plugin install looper@looper
> ```

> ⚠️ **Not verified by automated tests**: `/plugin` is a Claude Code REPL built-in and cannot be invoked via `claude -p`. Run manually in a Claude Code session; not covered by skill-test pipeline (looper Stage 5).

### Option B — install script

```bash
git clone https://github.com/easyfan/looper
cd looper
bash install.sh
# preview without writing
bash install.sh --dry-run
# remove installed files
bash install.sh --uninstall
# custom Claude config directory (flag or env var)
bash install.sh --target=~/.claude
CLAUDE_DIR=~/.claude bash install.sh
```

Installs:
- `skills/looper/ → ~/.claude/skills/looper/`

> ✅ **Verified**: covered by the skill-test pipeline (looper Stage 5).

### Option C — manual

```bash
cp -r skills/looper ~/.claude/skills/looper
```

> ✅ **Verified**: covered by the skill-test pipeline (looper Stage 5).

## Usage

```
/looper --plugin <name>                          # verify packer/<name>/
/looper --plugin <name> --plan a                 # Plan A only (install.sh path)
/looper --plugin <name> --plan b                 # Plan B only (claude plugin install path)
/looper --plugin <name> --image <image>          # explicit container image
/looper --help                                   # show usage
```

## Requirements

- **Docker** (must be available on the host; when running inside a devcontainer, looper detects this and exits gracefully with a hint)
- **CC runtime image** (`cc-runtime-minimal` — see below; includes python3 for T5 eval execution)

## Image Strategy

looper resolves the container image using the following priority order (result is persisted
to `packer/<name>/.looper-state.json` after the first run):

| Priority | Source | Notes |
|----------|--------|-------|
| 1 | `--image <image>` flag | Explicit override, always wins; not written to state cache |
| 2 | `.looper-state.json` cache | Reuses image from previous run |
| 3 | `.devcontainer/devcontainer.json` | Auto-reads the project's standard image |
| 4 | Locally available `cc-runtime-minimal` | Previously built or pulled |
| 5 | Fallback guidance | Outputs instructions for obtaining `cc-runtime-minimal` |

### Getting cc-runtime-minimal

**Pull (recommended):**
```bash
docker pull easyfan/agents-slim:cc-runtime-minimal
docker tag easyfan/agents-slim:cc-runtime-minimal cc-runtime-minimal
```

**Build locally** (for security auditing):
```bash
docker build -t cc-runtime-minimal assets/image/
```

Image source: [easyfan/agents-slim](https://github.com/easyfan/agents-slim)

## Test Plans

looper runs two independent verification plans. Use `--plan both` (default) to run all tests,
or `--plan a` / `--plan b` to run one plan at a time.

| Plan | Steps | What is verified |
|------|-------|-----------------|
| A | T2 (A1–A7) | `install.sh` interface compliance, file installation, idempotency, uninstall, dry-run |
| B | T2b (B1–B8) | `claude plugin install` path (marketplace / local `plugin.json`) |

Additional tests always run regardless of `--plan`:

| Test | What is verified |
|------|-----------------|
| T0 | `plugin.json` manifest validation (host, once) |
| T1 | CC availability inside container |
| T3 | Skill trigger accuracy (single `claude -p` call) |
| T5 | Behavioral eval suite (runs `evals/evals.json` inside container; skipped when `disable_t5: true`) |

## Development

### Evals

`evals/evals.json` contains 7 test cases covering the current `--plugin`-only CLI:

| ID | Scenario | What is verified |
|----|----------|-----------------|
| 1 | `/looper --help` | Help text contains all four flags and at least one usage example; no Docker executed |
| 2 | `/looper` (no args) | Outputs usage guide; no Docker operations |
| 3 | `/looper --plugin xyz_nonexistent_...` | Outputs plugin-not-found error; no container started |
| 4 | `/looper --plugin looper --plan a` | Plan A only; T2b result is skip |
| 5 | `/looper --plugin looper --plan b` | Plan B only; T2 result is skip |
| 6 | `/looper --plugin looper --image my-custom-registry:cc-runtime` | `--image` flag; user-specified strategy; image name appears in output |
| 7 | `/looper --plugin looper` | Plugin not found in container; graceful error output |

### Opting out of T5

Add `"disable_t5": true` at the top level of `evals.json` to prevent looper from running the
eval suite inside the container. Use this when the skill under test is looper itself (running
`/looper` inside the container would require Docker-in-Docker) or any other tool that cannot
run inside the clean environment.

```json
{
  "skill_name": "looper",
  "disable_t5": true,
  "evals": [ ... ]
}
```

looper will note `eval suite: skipped (disable_t5=true in evals.json)` in the Step 4 progress
output. The overall result is not failed.

## Package Structure

```
looper/
├── .claude-plugin/
│   ├── plugin.json             # plugin manifest
│   └── marketplace.json        # marketplace entry
├── DESIGN.md                   # architecture notes
├── skills/looper/
│   └── SKILL.md                # installed to ~/.claude/skills/looper/
├── scripts/
│   ├── run.sh                  # core verification logic
│   └── run_eval_suite.py       # T5 eval runner (injected into container)
├── assets/image/               # cc-runtime-minimal image source
│   ├── Dockerfile
│   └── .github/workflows/build-push.yml
├── test/
│   ├── test-a.sh               # Plan A host-level tests
│   ├── test-b.sh               # Plan B host-level tests
│   └── test-all.sh
├── evals/evals.json
├── install.sh
└── package.json
```
