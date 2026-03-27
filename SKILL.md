---
name: looper
description: Deployment verification tool for Claude Code — runs installation integrity and trigger accuracy tests for a command/skill/plugin inside a clean Docker CC container. Used as Stage 5 of the skill-test pipeline.
---

# looper package

## Files

- `commands/looper.md` → `~/.claude/commands/looper.md`

## Prerequisites

- Docker (available directly on the **host machine**; when running inside a devcontainer/container, Step 2 detects this and exits gracefully with a DinD-not-supported notice)
- `/workspace/looper/.claude.json` (CC onboarding-skip config; already present in the looper/ directory)
- macOS: Docker Desktop must have `/Users` path sharing enabled (on by default); temp directories automatically use `$HOME` to avoid `/tmp` mount failures

## Image selection strategy

On **first invocation**, looper determines the image using the following priority order and persists the choice to `looper/.looper-state.json`. Subsequent calls reuse the cached config by default:

| Priority | Source | Condition | Strategy label |
|----------|--------|-----------|----------------|
| 1 (highest) | `.devcontainer/devcontainer.json` | File exists and contains an `image` field | `devcontainer (auto-detected)` |
| 2 | `--image <image>` flag | Explicitly specified at call time | `user-specified (--image flag)` |
| 3 | Local `cc-runtime-minimal` image | Previously built or pulled | `local-cached` |
| 4 (fallback) | Guide user to obtain `cc-runtime-minimal` | None of the above apply | `fallback (guided build/pull)` |

> **Fallback behavior**: looper outputs a guidance prompt with two options:
> - Build locally from `assets/Dockerfile`: `docker build -t cc-runtime-minimal packer/looper/assets/`
> - Pull a pre-built image from DockerHub: `docker pull <your-org>/cc-runtime-minimal:latest && docker tag ... cc-runtime-minimal`
>
> After completing either option, re-run `/looper` or pass `--image` directly.
>
> To switch images on a non-first run, use `--image <image>` to override the cached config.

The image used and the strategy applied are recorded in the execution report (Step 7 `.md` + Step 9 terminal output).

## Known limitations

| Scenario | Behavior |
|----------|----------|
| Running inside devcontainer / container | Step 2 detects `/.dockerenv`, outputs DinD-not-supported notice, exits 0 |
| macOS Docker Desktop + `/tmp` | Step 4 automatically uses `$HOME` for temp directory creation |
| Skill search depth | `find -maxdepth 8`, covers `~/.claude/plugins/cache/.../skills/<name>` (depth=7) |
| Image state file | `looper/.looper-state.json`; auto-read on non-first runs; `--image` flag overrides |

## Purpose

Validates skill behavior in a completely clean CC environment (no other toolchain installed) as Stage 5 of the skill-test pipeline — ensures the skill is triggerable after installation with no missing files.
