#!/usr/bin/env bash
# Regression check: confirms backend-observability still flags the hard-rule
# violations deliberately planted in bad_observability.py. Re-run after any
# edit to skills/backend-observability/SKILL.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/backend-observability/bad_observability.py"

PROMPT=$(cat <<'EOF'
Using ONLY the backend-observability skill's hard-rule table (the "Hard rules — always
flag as violations" section), review the file below. For every hard-rule
violation you find, output one line exactly in this form:

VIOLATION: <short rule name from the table>

Do not output anything else: no fixes, no structural-preference notes, no prose.
If you find no hard-rule violations, output NONE.

--- file: bad_observability.py ---
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

check "print|unstructured|plain-text"      "print()/unstructured logging"
check "correlation|request.id"             "missing correlation/request ID"
check "password|token|secret|pii|plaintext" "secret/token/PII logged in plaintext"
check "except|swallow|pass"                "swallowed exception with no log line"
check "exc_info|logger\.exception|stack.trace" "logger.error(str(e)) discards stack trace"

if [ "$FAIL" -eq 0 ]; then
  echo "OK: all expected hard-rule violations detected"
else
  echo "FAIL: backend-observability no longer detects one or more expected violations"
  exit 1
fi
