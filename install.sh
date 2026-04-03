#!/usr/bin/env bash
# install.sh — looper Claude Code plugin installer
# ✅ Verified by automated tests: this install path is covered by the skill-test pipeline (looper Stage 5).
#
# Usage:
#   ./install.sh              # install to ~/.claude/
#   ./install.sh --dry-run    # preview without writing
#   ./install.sh --uninstall  # remove installed files
#   CLAUDE_DIR=/path ./install.sh  # custom target

set -euo pipefail

# ── Resolve real script dir (symlink-safe, same pattern as ecc) ──────────────
SCRIPT_PATH="$0"
while [ -L "$SCRIPT_PATH" ]; do
  link_dir="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
  SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
  [[ "$SCRIPT_PATH" != /* ]] && SCRIPT_PATH="$link_dir/$SCRIPT_PATH"
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

# ── Config ───────────────────────────────────────────────────────────────────
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
DRY_RUN=false
UNINSTALL=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY_RUN=true ;;
    --uninstall)  UNINSTALL=true ;;
    --target=*)   CLAUDE_DIR="${arg#--target=}" ;;
    --help|-h)
      echo "Usage: ./install.sh [--dry-run] [--uninstall] [--target=<path>]"
      echo "  CLAUDE_DIR=/path ./install.sh   # custom Claude config dir (env var)"
      echo "  ./install.sh --target=/path     # custom Claude config dir (flag)"
      exit 0 ;;
  esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────
info()  { printf "  %s\n" "$*"; }
ok()    { printf "  \033[32m✓\033[0m %s\n" "$*"; }
skip()  { printf "  \033[2m– %s (up to date)\033[0m\n" "$*"; }
warn()  { printf "  \033[33m! %s\033[0m\n" "$*"; }
run()   { $DRY_RUN || "$@"; }

SKILL_SRC="skills/looper"
SKILL_DST="skills/looper"

# ── Header ───────────────────────────────────────────────────────────────────
echo ""
echo "  looper — Claude Code plugin v$(grep '"version"' "$SCRIPT_DIR/package.json" | head -1 | grep -o '[0-9.]*')"
echo "  Target: $CLAUDE_DIR"
$DRY_RUN && echo "  Mode: DRY RUN (no files modified)"
echo ""

# ── Check Claude Code ─────────────────────────────────────────────────────────
if ! command -v claude &>/dev/null; then
  warn "'claude' CLI not found. Install Claude Code first: https://claude.ai/code"
  echo ""
fi

# ── Uninstall ─────────────────────────────────────────────────────────────────
if $UNINSTALL; then
  echo "  Uninstalling..."
  skill_dst="$CLAUDE_DIR/$SKILL_DST"
  if [ -d "$skill_dst" ]; then
    run rm -rf "$skill_dst"
    ok "Removed $skill_dst"
  else
    skip "$SKILL_DST (not found)"
  fi
  echo ""
  echo "  Uninstall complete."
  echo ""
  exit 0
fi

# ── Install ───────────────────────────────────────────────────────────────────
changed=0

# ── Skill ─────────────────────────────────────────────────────────────────────
skill_src="$SCRIPT_DIR/$SKILL_SRC"
skill_dst="$CLAUDE_DIR/$SKILL_DST"
if [ -f "$skill_dst/SKILL.md" ] && diff -q "$skill_src/SKILL.md" "$skill_dst/SKILL.md" &>/dev/null; then
  skip "$SKILL_DST"
else
  [ -d "$skill_dst" ] && info "Updating  $SKILL_DST..." || info "Installing $SKILL_DST..."
  run mkdir -p "$skill_dst"
  run cp -r "$skill_src/." "$skill_dst/"
  ok "$SKILL_DST → $skill_dst"
  changed=$((changed + 1))
fi

# ── Footer ────────────────────────────────────────────────────────────────────
echo ""
if $DRY_RUN; then
  echo "  [dry-run] $changed file(s) would be modified."
else
  echo "  Done! $changed file(s) installed."
  echo ""
  echo "  Quick start:"
  echo "    /looper --plugin <name>           # verify plugin deployment"
  echo "    /looper --plugin <name> --plan a  # Plan A only (install.sh path)"
  echo "    /looper --plugin <name> --plan b  # Plan B only (claude plugin install path)"
fi
echo ""
