# looper

Deploy-time verification for Claude Code commands, skills, and plugins — runs installation, trigger-accuracy, and behavioral eval suite (T5) tests inside a clean Docker CC container. Used as Stage 5 of the skill-test pipeline.

## Install

```bash
bash install.sh
# or specify a custom Claude config directory
bash install.sh --target ~/.claude
# or using the CLAUDE_DIR convention
CLAUDE_DIR=~/.claude bash install.sh
```

Installs: `commands/looper.md → ~/.claude/commands/looper.md`

> ✅ **Verified**: covered by the skill-test pipeline (looper Stage 5).

## Usage

```
/looper --command <name>     # verify ~/.claude/commands/<name>.md
/looper --skill <name>       # verify ~/.claude/skills/<name>/
/looper --plugin <pkg>       # install and verify packer/<pkg>/
```

Optional `--image <image>` flag to specify a container image explicitly.

## Requirements

- **Docker** (must be available on the host; when running inside a devcontainer, looper detects this and exits gracefully with a hint)
- **CC runtime image** (`cc-runtime-minimal` — see below; includes python3 for T5 eval execution)

## Image Strategy

looper resolves the container image using the following priority order (result is persisted to `looper/.looper-state.json` after the first run):

| Priority | Source | Notes |
|----------|--------|-------|
| 1 | `.devcontainer/devcontainer.json` | Auto-reads the project's standard image |
| 2 | `--image <image>` flag | Explicit override |
| 3 | Locally available `cc-runtime-minimal` | Previously built or pulled |
| 4 | Fallback guidance | Outputs instructions for obtaining `cc-runtime-minimal` |

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

## Development

### Evals

`evals/evals.json` contains 10 test cases covering argument parsing, target resolution, Docker availability detection, image strategy branches, and T5 eval suite execution:

| ID | Scenario | What is verified |
|----|----------|-----------------|
| 1 | `/looper --command patterns` | Argument parsing, target file existence check, Docker availability; graceful exit when Docker unavailable; T5 triggered when Docker available (evals.json present) |
| 2 | `/looper --command xyz_nonexistent_...` | Outputs "❌ target not found" when target is missing; no container started |
| 3 | `/looper --plugin patterns` | TYPE=plugin path: locates `packer/` directory, runs `install.sh`, then tests |
| 4 | `/looper` (no args) | Outputs full usage guide (all four argument types); no Docker operations |
| 5 | `/looper --skill skill-creator` | TYPE=skill path: searches `~/.claude` for directory, builds clean environment, tests trigger |
| 6 | `/looper --command patterns --image my-custom-registry:cc-runtime` | `--image` flag sets user-specified strategy, skips devcontainer detection |
| 7 | Same as above (with pre-existing `.looper-state.json`) | Reads cached state file, reuses recorded image without re-detecting |
| 8 | Image strategy output verification | Execution output contains image name and strategy label (devcontainer / user-specified / fallback / cached) |
| 9 | T5 active — `/looper --plugin patterns` (evals.json present) | Step 4 injects eval runner + evals.json; if Docker available, T5 runs and outputs EVAL_SUITE_RESULT |
| 10 | T5 skip — `/looper --skill skill-creator` (no evals.json at skill path) | Step 4 notes "eval suite: skipped"; T5 row shows ⏭️; overall result not failed due to T5 skip |

### Opting out of T5

Add `"disable_t5": true` at the top level of `evals.json` to prevent looper from running the eval suite inside the container. Use this when the skill under test is looper itself (running `/looper` inside the container would require Docker-in-Docker) or any other tool that cannot run inside the clean environment.

```json
{
  "skill_name": "looper",
  "disable_t5": true,
  "evals": [ ... ]
}
```

looper will note `eval suite: skipped (disable_t5=true in evals.json)` in the Step 4 progress output. The overall result is not failed.

Manual testing (in a Claude Code session):
```bash
/looper --command patterns     # eval 1
/looper                        # eval 4 — view usage guide
```

Run all evals using skill-creator's eval loop (if installed):
```bash
python ~/.claude/skills/skill-creator/scripts/run_loop.py \
  --skill-path ~/.claude/commands/looper.md \
  --evals-path evals/evals.json
```

## Package Structure

```
looper/
├── commands/looper.md      # installed to ~/.claude/commands/
├── assets/
│   └── image/              # cc-runtime-minimal image source
│       ├── Dockerfile
│       └── .github/workflows/build-push.yml
├── evals/evals.json
├── install.sh
└── SKILL.md
```
