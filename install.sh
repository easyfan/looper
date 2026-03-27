#!/usr/bin/env bash
set -euo pipefail

# looper installer
#
# Usage:
#   bash install.sh [--target <claude_home>]
#   CLAUDE_DIR=<claude_home> bash install.sh      # packer convention (lower priority than --target)
#
# Installs:
#   commands/looper.md → <claude_home>/commands/looper.md
#
# Runtime notes (not handled by install.sh — for reference only):
#   Image selection strategy (4-level priority):
#     1. devcontainer.json image (auto-detected)
#     2. --image <image> flag (explicitly specified)
#     3. Local cc-runtime-minimal (previously built or pulled)
#     4. fallback: guide user to build or pull cc-runtime-minimal, then retry
#   Obtain cc-runtime-minimal (pick one):
#     pull:  docker pull easyfan/agents-slim:cc-runtime-minimal && docker tag easyfan/agents-slim:cc-runtime-minimal cc-runtime-minimal
#     build: docker build -t cc-runtime-minimal <pkg>/assets/image/
#   After first run, image config is persisted to <project>/looper/.looper-state.json; reused on subsequent calls.
#   To switch images: /looper --command <name> --image <image>

TARGET="${CLAUDE_DIR:-${HOME}/.claude}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "${TARGET}/commands"
cp "${SCRIPT_DIR}/commands/looper.md" "${TARGET}/commands/looper.md"
echo "✅ looper installed → ${TARGET}/commands/looper.md"
