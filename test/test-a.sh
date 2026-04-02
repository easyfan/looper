#!/usr/bin/env bash
# test-a.sh — Plan A: install.sh path integration test
#
# Tests all three plugins via their install.sh from a clean host state.
# Covers: dry-run → uninstall → install → idempotency → verify → uninstall → verify clean
#
# Usage:
#   bash packer/looper/test/test-a.sh              # test all three
#   bash packer/looper/test/test-a.sh news-digest  # test one plugin

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKER_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

PLUGINS=(news-digest skill-review readme-i18n)
[[ $# -gt 0 ]] && PLUGINS=("$@")

ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
fail() { printf "  \033[31m✗\033[0m %s\n" "$*"; FAILED=$((FAILED+1)); }
info() { printf "  %s\n" "$*"; }
FAILED=0

echo ""
echo "=== Plan A: install.sh path ==="
echo "    plugins: ${PLUGINS[*]}"
echo ""

# ── Step 1: Uninstall (ensure clean state) ────────────────────────────────────
echo "── Step 1: Uninstall (clean state) ──"
for name in "${PLUGINS[@]}"; do
  bash "$PACKER_DIR/$name/install.sh" --uninstall 2>&1 | grep -E "✓|Removed" || true
done
echo ""

# ── Step 2: Verify clean ──────────────────────────────────────────────────────
echo "── Step 2: Verify clean ──"
clean=true
for name in "${PLUGINS[@]}"; do
  case "$name" in
    news-digest)
      [[ -f ~/.claude/commands/news-digest.md ]] && { fail "still present: commands/news-digest.md"; clean=false; } || true
      [[ -f ~/.claude/agents/news-learner.md ]]  && { fail "still present: agents/news-learner.md"; clean=false; } || true
      [[ -d ~/.claude/skills/news-digest ]]       && { fail "still present: skills/news-digest"; clean=false; } || true
      ;;
    skill-review)
      [[ -f ~/.claude/commands/skill-review.md ]] && { fail "still present: commands/skill-review.md"; clean=false; } || true
      [[ -d ~/.claude/skills/validate-plugin-manifest ]] && { fail "still present: skills/validate-plugin-manifest"; clean=false; } || true
      ;;
    readme-i18n)
      [[ -d ~/.claude/skills/readme-i18n ]] && { fail "still present: skills/readme-i18n"; clean=false; } || true
      ;;
  esac
done
$clean && ok "clean state confirmed"
echo ""

# ── Step 3: Dry-run ───────────────────────────────────────────────────────────
echo "── Step 3: Dry-run ──"
for name in "${PLUGINS[@]}"; do
  result=$(bash "$PACKER_DIR/$name/install.sh" --dry-run 2>&1)
  count=$(echo "$result" | grep -oE '[0-9]+ file' | grep -oE '[0-9]+' || echo "0")
  if echo "$result" | grep -q "would be modified" && [[ "$count" -gt 0 ]]; then
    ok "dry-run: $name ($count file(s) would be modified)"
  else
    fail "dry-run unexpected output: $name — $count file(s)"
  fi
done
echo ""

# ── Step 4: Install ───────────────────────────────────────────────────────────
echo "── Step 4: Install ──"
for name in "${PLUGINS[@]}"; do
  result=$(bash "$PACKER_DIR/$name/install.sh" 2>&1)
  count=$(echo "$result" | grep -oE 'Done! [0-9]+' | grep -oE '[0-9]+' || echo "0")
  if echo "$result" | grep -q "Done!" && [[ "$count" -gt 0 ]]; then
    ok "installed: $name ($count item(s))"
  else
    fail "install unexpected output: $name — result: $(echo "$result" | tail -2)"
  fi
done
echo ""

# ── Step 5: Idempotency ───────────────────────────────────────────────────────
echo "── Step 5: Idempotency (re-install should change 0 files) ──"
for name in "${PLUGINS[@]}"; do
  result=$(bash "$PACKER_DIR/$name/install.sh" 2>&1)
  if echo "$result" | grep -qE "Done! 0 (file|item)"; then
    ok "idempotent: $name"
  else
    fail "not idempotent: $name — $(echo "$result" | grep Done)"
  fi
done
echo ""

# ── Step 6: Verify installed files ───────────────────────────────────────────
echo "── Step 6: Verify installed files ──"
declare -a CHECKS=(
  "news-digest:f:~/.claude/commands/news-digest.md"
  "news-digest:f:~/.claude/agents/news-learner.md"
  "news-digest:d:~/.claude/skills/news-digest"
  "skill-review:f:~/.claude/commands/skill-review.md"
  "skill-review:f:~/.claude/agents/skill-reviewer-s1.md"
  "skill-review:f:~/.claude/agents/skill-reporter.md"
  "skill-review:d:~/.claude/skills/validate-plugin-manifest"
  "readme-i18n:d:~/.claude/skills/readme-i18n"
)
for check in "${CHECKS[@]}"; do
  IFS=: read -r plugin type path <<< "$check"
  # skip if not in PLUGINS list
  printf '%s\n' "${PLUGINS[@]}" | grep -qx "$plugin" || continue
  expanded="${path/#\~/$HOME}"
  if [[ "$type" == "f" && -f "$expanded" ]] || [[ "$type" == "d" && -d "$expanded" ]]; then
    ok "exists: ${path##*/} ($plugin)"
  else
    fail "missing: $path ($plugin)"
  fi
done
echo ""

# ── Step 7: Uninstall ─────────────────────────────────────────────────────────
echo "── Step 7: Uninstall ──"
for name in "${PLUGINS[@]}"; do
  result=$(bash "$PACKER_DIR/$name/install.sh" --uninstall 2>&1)
  removed=$(echo "$result" | grep -c "Removed" || true)
  if [[ "$removed" -gt 0 ]]; then
    ok "uninstalled: $name ($removed item(s) removed)"
  else
    fail "uninstall had no removals: $name"
  fi
done
echo ""

# ── Step 8: Verify clean after uninstall ─────────────────────────────────────
echo "── Step 8: Verify clean after uninstall ──"
any_left=false
for name in "${PLUGINS[@]}"; do
  case "$name" in
    news-digest)
      [[ -f ~/.claude/commands/news-digest.md ]] && { fail "still present after uninstall: commands/news-digest.md"; any_left=true; } || true
      [[ -f ~/.claude/agents/news-learner.md ]]  && { fail "still present after uninstall: agents/news-learner.md"; any_left=true; } || true
      [[ -d ~/.claude/skills/news-digest ]]       && { fail "still present after uninstall: skills/news-digest"; any_left=true; } || true
      ;;
    skill-review)
      [[ -f ~/.claude/commands/skill-review.md ]] && { fail "still present after uninstall: commands/skill-review.md"; any_left=true; } || true
      [[ -f ~/.claude/agents/skill-reviewer-s1.md ]] && { fail "still present after uninstall: agents/skill-reviewer-s1.md"; any_left=true; } || true
      [[ -d ~/.claude/skills/validate-plugin-manifest ]] && { fail "still present after uninstall: skills/validate-plugin-manifest"; any_left=true; } || true
      ;;
    readme-i18n)
      [[ -d ~/.claude/skills/readme-i18n ]] && { fail "still present after uninstall: skills/readme-i18n"; any_left=true; } || true
      ;;
  esac
done
$any_left || ok "clean after uninstall"
echo ""

# ── Result ────────────────────────────────────────────────────────────────────
if [[ $FAILED -eq 0 ]]; then
  echo "  \033[32mPlan A: All checks passed.\033[0m"
  echo ""
  exit 0
else
  echo "  \033[31mPlan A: $FAILED check(s) failed.\033[0m"
  echo ""
  exit 1
fi
