#!/usr/bin/env bash
# Regression check: confirms flask-architecture still flags the hard-rule
# violations deliberately planted in bad_flask.py. Re-run after any edit to
# skills/flask-architecture/SKILL.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/flask-architecture/bad_flask.py"

PROMPT=$(cat <<'EOF'
Using ONLY the flask-architecture skill's hard-rule table (the "Hard rules — always
flag as violations" section), review the Flask file below. For every hard-rule
violation you find, output one line exactly in this form:

VIOLATION: <short rule name from the table>

Do not output anything else: no fixes, no structural-preference notes, no prose.
If you find no hard-rule violations, output NONE.

--- file: bad_flask.py ---
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

check "Flask\(__name__\)|module.level|factory"      "module-level Flask() instance instead of application factory"
check "hardcoded|config value"                       "hardcoded config value in source"
check "get_json|schema|validation"                   "raw request.get_json() with no schema validation"
check "blocking|requests\.get|time\.sleep|async"      "blocking call inside an async def view"

if [ "$FAIL" -eq 0 ]; then
  echo "OK: all expected hard-rule violations detected"
else
  echo "FAIL: flask-architecture no longer detects one or more expected violations"
  exit 1
fi
