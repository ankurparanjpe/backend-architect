#!/usr/bin/env bash
# Regression check: confirms testing-standards still flags the hard-rule
# violations deliberately planted in bad_testing.py. Re-run after any edit to
# skills/testing-standards/SKILL.md — and after any edit to
# fastapi-architecture's "Mocking the database in integration tests" row, since
# the two cross-reference each other.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/testing-standards/bad_testing.py"

PROMPT=$(cat <<'EOF'
Using ONLY the testing-standards skill's hard-rule table (the "Hard rules — always
flag as violations" section), review the file below. For every hard-rule
violation you find, output one line exactly in this form:

VIOLATION: <short rule name from the table>

Do not output anything else: no fixes, no structural-preference notes, no prose.
If you find no hard-rule violations, output NONE.

--- file: bad_testing.py ---
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

check "integration test.*mock|mock.*(the )?(database|boundary)"  "integration test mocking the boundary it tests"
check "order.depend|another test ran|isolat|shared.*(module|mutable|state)" "order-dependent test / shared mutable state"
check "teardown|persistent state|leaves.*state"                  "test leaves persistent state behind"
check "patch|under test"                                         "business logic under test patched out"
check "critical path|auth|permission|payment|mutation"           "critical path with no test"
check "response shape|contract|status.code.only|field"           "consumer-facing response shape unguarded"

if [ "$FAIL" -eq 0 ]; then
  echo "OK: all expected hard-rule violations detected"
else
  echo "FAIL: testing-standards no longer detects one or more expected violations"
  exit 1
fi
