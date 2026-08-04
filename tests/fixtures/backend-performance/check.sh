#!/usr/bin/env bash
# Regression check: confirms backend-performance still flags the hard-rule
# violations deliberately planted in bad_performance.py. Re-run after any edit
# to skills/backend-performance/SKILL.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/backend-performance/bad_performance.py"

PROMPT=$(cat <<'EOF'
Using ONLY the backend-performance skill's hard-rule table (the "Hard rules — always
flag as violations" section), review the file below. For every hard-rule
violation you find, output one line exactly in this form:

VIOLATION: <short rule name from the table>

Do not output anything else: no fixes, no structural-preference notes, no prose.
If you find no hard-rule violations, output NONE.

--- file: bad_performance.py ---
EOF
cat "$FIXTURE"
)

OUTPUT=$(echo "$PROMPT" | claude -p --plugin-dir "$ROOT" --permission-mode bypassPermissions)
echo "$OUTPUT"
echo "---"

FAIL=0
check() {
  if ! grep -qiE "$1" <<< "$OUTPUT"; then
    echo "MISSING expected violation: $2"
    FAIL=1
  fi
}

check "pagination|limit|unbounded|bound"   "list endpoint with no pagination/bound enforcement"
check "client|session|reuse|pool"          "new HTTP/DB client constructed per call instead of reused"

if [ "$FAIL" -eq 0 ]; then
  echo "OK: all expected hard-rule violations detected"
else
  echo "FAIL: backend-performance no longer detects one or more expected violations"
  exit 1
fi
