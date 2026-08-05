#!/usr/bin/env bash
# Regression check: confirms resilience-patterns still flags the hard-rule
# violations deliberately planted in bad_resilience.py. Re-run after any edit to
# skills/resilience-patterns/SKILL.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/resilience-patterns/bad_resilience.py"

PROMPT=$(cat <<'EOF'
Using ONLY the resilience-patterns skill's hard-rule table (the "Hard rules —
always flag as violations" section), review the file below. For every hard-rule
violation you find, output one line exactly in this form:

VIOLATION: <short rule name from the table>

Do not output anything else: no fixes, no structural-preference notes, no prose.
If you find no hard-rule violations, output NONE.

--- file: bad_resilience.py ---
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

check "no explicit timeout|without.*timeout|missing.*timeout|no timeout"  "outbound call with no explicit timeout"
check "idempoten"                                    "retry on non-idempotent POST with no usable idempotency key"
check "backoff|tight.loop"                           "retries with no backoff"
check "fail.fast|circuit|breaker"                     "no fail-fast path for a repeatedly failing dependency"
check "critical path|non.critical|unguarded|isolat"   "non-critical call unguarded on the critical path"
check "swallow|except: ?pass|no record|silent"        "failure swallowed with no record"
check "re.run|resum|idempotent step|dead.letter"      "task body not safe to re-run after interruption"

if [ "$FAIL" -eq 0 ]; then
  echo "OK: all expected hard-rule violations detected"
else
  echo "FAIL: resilience-patterns no longer detects one or more expected violations"
  exit 1
fi
