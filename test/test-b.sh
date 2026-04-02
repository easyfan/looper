#!/usr/bin/env bash
# test-b.sh — Plan B: claude plugin install path integration test
#
# Tests all three plugins via `claude plugin install` from a clean state.
# Steps: reset → marketplace update → schema validation → install → sha verify → file presence
#
# Usage:
#   bash packer/looper/test/test-b.sh              # test all three
#   bash packer/looper/test/test-b.sh news-digest  # test one plugin

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
echo "=== Plan B: claude plugin install path ==="
echo "    plugins: ${PLUGINS[*]}"
echo ""

# ── Step 1: Reset to clean state ─────────────────────────────────────────────
echo "── Step 1: Reset to clean state ──"
for name in "${PLUGINS[@]}"; do
  claude plugin uninstall "$name" 2>/dev/null | grep -E "Successfully|already" || true
  rm -rf ~/.claude/plugins/cache/"$name"
  info "cache cleared: $name"
done
echo ""

# ── Step 2: Marketplace update (critical for test repeatability) ──────────────
echo "── Step 2: Marketplace update ──"
info "(Ensures marketplace cache is current so install uses latest sha)"
for name in "${PLUGINS[@]}"; do
  result=$(claude plugin marketplace update "$name" 2>&1)
  if echo "$result" | grep -q "Successfully"; then
    ok "marketplace updated: $name"
  else
    fail "marketplace update failed: $name — $result"
  fi
done
echo ""

# ── Step 3: Schema validation ─────────────────────────────────────────────────
echo "── Step 3: Schema validation ──"
for name in "${PLUGINS[@]}"; do
  plugin_dir="$PACKER_DIR/$name"

  # plugin.json — validate always
  result=$(claude plugin validate "$plugin_dir/.claude-plugin/plugin.json" 2>&1)
  if echo "$result" | grep -q "✔ Validation passed"; then
    ok "plugin.json valid: $name"
  else
    fail "plugin.json invalid: $name — $(echo "$result" | grep -v '^$' | tail -3)"
  fi

  # marketplace.json — skipped pending anthropics/claude-code#42412
  # (validator incorrectly rejects $schema and description fields that official marketplace uses)
  info "marketplace.json: skipped (validator bug #42412 — false negative on \$schema/description)"
done
echo ""

# ── Step 4: Install ───────────────────────────────────────────────────────────
echo "── Step 4: Install ──"
for name in "${PLUGINS[@]}"; do
  result=$(claude plugin install "$name" 2>&1)
  if echo "$result" | grep -q "Successfully installed"; then
    ok "installed: $name"
  else
    fail "install failed: $name — $result"
  fi
done
echo ""

# ── Step 5: Version SHA verification ─────────────────────────────────────────
# Verify CC installed the sha that matches the marketplace registry.
# Mismatch = CC used stale cache (the bug we found in 2026-04-02 testing).
echo "── Step 5: Version SHA verification ──"
for name in "${PLUGINS[@]}"; do
  registry_json="$HOME/.claude/plugins/marketplaces/$name/.claude-plugin/marketplace.json"
  if [[ ! -f "$registry_json" ]]; then
    fail "marketplace registry not found for $name"; continue
  fi
  registry_sha=$(python3 -c "import json,sys; d=json.load(open('$registry_json')); print(d['plugins'][0]['source']['sha'][:7])" 2>/dev/null) \
    || { fail "cannot parse marketplace registry sha for $name"; continue; }

  cache_dirs=( ~/.claude/plugins/cache/"$name"/"$name"/*/ )
  if [[ ! -d "${cache_dirs[0]}" ]]; then
    fail "no versioned cache dir for $name"; continue
  fi
  cache_dir="${cache_dirs[0]}"
  installed_sha=$(cd "$cache_dir" && git log --oneline -1 2>/dev/null | awk '{print $1}')

  if [[ "$installed_sha" == "$registry_sha"* ]] || [[ "$registry_sha" == "$installed_sha"* ]]; then
    ok "sha matches: $name — $installed_sha"
  else
    fail "SHA MISMATCH: $name — installed=$installed_sha, registry=$registry_sha (stale cache?)"
  fi
done
echo ""

# ── Step 6: File presence verification ───────────────────────────────────────
# NOTE on CC plugin install behavior (confirmed 2026-04-02, CC v2.1.90):
#   - commands/ and agents/ are NOT auto-deployed to ~/.claude/ by CC plugin install
#   - skills/ are NOT copied to ~/.claude/skills/ either
#   - ALL content is loaded dynamically from the plugin cache at runtime
#   - install.sh is NOT executed (plugin.json "install" field is unrecognized/ignored)
# Therefore we verify presence in the plugin cache, not in ~/.claude/ directly.
echo "── Step 6: File presence verification (in plugin cache) ──"

expected_commands() {
  case "$1" in
    news-digest)  echo "news-digest.md" ;;
    skill-review) echo "skill-review.md" ;;
    readme-i18n)  echo "" ;;
  esac
}
expected_agents() {
  case "$1" in
    news-digest)  echo "news-learner.md" ;;
    skill-review) echo "skill-reviewer-s1.md skill-reviewer-s2.md skill-researcher.md skill-reviewer-s4.md skill-challenger.md skill-reporter.md" ;;
    readme-i18n)  echo "" ;;
  esac
}
expected_skill() {
  case "$1" in
    news-digest)  echo "news-digest" ;;
    skill-review) echo "validate-plugin-manifest" ;;
    readme-i18n)  echo "readme-i18n" ;;
  esac
}

for name in "${PLUGINS[@]}"; do
  cache_dirs=( ~/.claude/plugins/cache/"$name"/"$name"/*/ )
  if [[ ! -d "${cache_dirs[0]}" ]]; then
    fail "no versioned cache dir for $name"; continue
  fi
  cache_dir="${cache_dirs[0]}"

  for f in $(expected_commands "$name"); do
    [[ -z "$f" ]] && continue
    [[ -f "$cache_dir/commands/$f" ]] && ok "command in cache: $f" || fail "command missing from cache: $f"
  done

  for f in $(expected_agents "$name"); do
    [[ -z "$f" ]] && continue
    [[ -f "$cache_dir/agents/$f" ]] && ok "agent in cache: $f" || fail "agent missing from cache: $f"
  done

  skill_name=$(expected_skill "$name")
  skill_path="$cache_dir/skills/$skill_name/SKILL.md"
  [[ -f "$skill_path" ]] && ok "skill in cache: $skill_name" || fail "skill missing from cache: $skill_name"
done

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
if [[ $FAILED -eq 0 ]]; then
  echo "  \033[32mPlan B: All checks passed.\033[0m"
  echo ""
  exit 0
else
  echo "  \033[31mPlan B: $FAILED check(s) failed.\033[0m"
  echo ""
  exit 1
fi
