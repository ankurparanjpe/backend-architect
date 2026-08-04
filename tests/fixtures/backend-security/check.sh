#!/usr/bin/env bash
# Regression check: confirms backend-security still flags the hard-rule
# violations deliberately planted in bad_security.py. Re-run after any edit to
# skills/backend-security/SKILL.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/backend-security/bad_security.py"

PROMPT=$(cat <<'EOF'
Using ONLY the backend-security skill's hard-rule table (the "Hard rules — always
flag as violations" section), review the file below. For every hard-rule
violation you find, output one line exactly in this form:

VIOLATION: <short rule name from the table>

Do not output anything else: no fixes, no structural-preference notes, no prose.
If you find no hard-rule violations, output NONE.

--- file: bad_security.py ---
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

check "cors|wildcard|allow_origins"      "wildcard CORS origin with credentials"
check "secret|hardcoded"                 "hardcoded JWT secret"
check "extra|forbid|role|privileged"     "unforbidden extra fields / client-bound role"
check "long-lived|refresh|365"           "long-lived token used as client-side session token"
check "permission|inline|admin"          "inline permission check instead of centralized"
check "sql|injection|f-string|format"    "string-formatted SQL"

if [ "$FAIL" -eq 0 ]; then
  echo "OK: all expected hard-rule violations detected"
else
  echo "FAIL: backend-security no longer detects one or more expected violations"
  exit 1
fi
