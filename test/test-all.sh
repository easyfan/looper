#!/usr/bin/env bash
# test-all.sh — Run Plan A (install.sh) and Plan B (claude plugin install) in sequence.
#
# Usage:
#   bash packer/looper/test/test-all.sh          # run both plans
#   bash packer/looper/test/test-all.sh --plan-a # run Plan A only
#   bash packer/looper/test/test-all.sh --plan-b # run Plan B only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUN_A=true
RUN_B=true

for arg in "$@"; do
  case "$arg" in
    --plan-a) RUN_B=false ;;
    --plan-b) RUN_A=false ;;
  esac
done

FAILED=0

if $RUN_A; then
  bash "$SCRIPT_DIR/test-a.sh" || FAILED=$((FAILED+1))
fi

if $RUN_B; then
  bash "$SCRIPT_DIR/test-b.sh" || FAILED=$((FAILED+1))
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ $FAILED -eq 0 ]]; then
  echo "  \033[32m✓ All plans passed.\033[0m"
else
  echo "  \033[31m✗ $FAILED plan(s) failed.\033[0m"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

exit $FAILED
