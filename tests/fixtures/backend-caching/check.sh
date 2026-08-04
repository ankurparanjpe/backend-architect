#!/usr/bin/env bash
# Regression check: confirms backend-caching still flags the hard-rule
# violations deliberately planted in bad_caching.py. Re-run after any edit to
# skills/backend-caching/SKILL.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/backend-caching/bad_caching.py"

PROMPT=$(cat <<'EOF'
Using ONLY the backend-caching skill's hard-rule table (the "Hard rules — always
flag as violations" section), review the file below. For every hard-rule
violation you find, output one line exactly in this form:

VIOLATION: <short rule name from the table>

Do not output anything else: no fixes, no structural-preference notes, no prose.
If you find no hard-rule violations, output NONE.

--- file: bad_caching.py ---
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

check "unscoped|shared.*key|user.*scop"      "unscoped cache key mixing user data"
check "version|namespace"                    "unversioned/unnamespaced cache key"
check "ttl|invalidat"                        "caching with no TTL/invalidation path"
check "side.effect|webhook"                  "caching an operation with side effects"

if [ "$FAIL" -eq 0 ]; then
  echo "OK: all expected hard-rule violations detected"
else
  echo "FAIL: backend-caching no longer detects one or more expected violations"
  exit 1
fi
