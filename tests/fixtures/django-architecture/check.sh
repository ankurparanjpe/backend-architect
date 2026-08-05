#!/usr/bin/env bash
# Regression check: confirms django-architecture still flags the hard-rule
# violations deliberately planted in bad_django.py. Re-run after any edit to
# skills/django-architecture/SKILL.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/django-architecture/bad_django.py"

PROMPT=$(cat <<'EOF'
Using ONLY the django-architecture skill's hard-rule table (the "Hard rules — always
flag as violations" section), review the Django file below. For every hard-rule
violation you find, output one line exactly in this form:

VIOLATION: <short rule name from the table>

Do not output anything else: no fixes, no structural-preference notes, no prose.
If you find no hard-rule violations, output NONE.

--- file: bad_django.py ---
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

check "sync orm|synchronousonly|async def|async view"   "sync ORM call inside an async view"
check "n\+1|select_related|prefetch_related|eager"      "N+1 relation access with no eager loading"
check "debug"                                           "DEBUG = True in deployed settings"
check "allowed_hosts|host.?header"                      "ALLOWED_HOSTS = ['*']"
check "secret_key|hardcoded secret|django-insecure"     "hardcoded SECRET_KEY"
check "csrf"                                            "CSRF middleware removed / @csrf_exempt on a write"
check "request\.data|serializer|validat"                "raw request.data with no serializer validation"
check "__all__|fields"                                  "ModelSerializer fields = \"__all__\""
check "is_valid|ignored|raise_exception"                "is_valid() return value ignored"
check "session|client|reuse|pool"                       "requests.Session() constructed per call"

if [ "$FAIL" -eq 0 ]; then
  echo "OK: all expected hard-rule violations detected"
else
  echo "FAIL: django-architecture no longer detects one or more expected violations"
  exit 1
fi
