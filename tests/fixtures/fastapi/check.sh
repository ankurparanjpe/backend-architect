#!/usr/bin/env bash
# Regression check: confirms fastapi-architecture still flags the hard-rule
# violations deliberately planted in bad_fastapi.py. Re-run after any edit to
# skills/fastapi-architecture/SKILL.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/fastapi/bad_fastapi.py"

PROMPT=$(cat <<'EOF'
Using ONLY the fastapi-architecture skill's hard-rule table (the "Hard rules — always
flag as violations" section), review the FastAPI file below. For every hard-rule
violation you find, output one line exactly in this form:

VIOLATION: <short rule name from the table>

Do not output anything else: no fixes, no structural-preference notes, no prose.
If you find no hard-rule violations, output NONE.

--- file: bad_fastapi.py ---
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

check "on_event|lifespan"        "deprecated @app.on_event startup/shutdown"
check "requests\.get|blocking"   "blocking requests.get() inside async def"
check "bare|except"              "bare except around route body"
check "pool_size|max_overflow|pool.*default"  "pool_size/max_overflow left at defaults"
check "n\+1|selectinload|joinedload"          "N+1 query pattern instead of eager loading"
check "response_model"                        "missing response_model / full ORM row serialized"
check "pytest|tests\.factories|dev depend|dependency group|dev tooling"  "dev/test-only package imported by application code"

if [ "$FAIL" -eq 0 ]; then
  echo "OK: all expected hard-rule violations detected"
else
  echo "FAIL: fastapi-architecture no longer detects one or more expected violations"
  exit 1
fi
