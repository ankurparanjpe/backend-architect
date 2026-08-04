#!/usr/bin/env bash
# Regression check for the /audit-architecture command: confirms it dispatches to
# all 5 skills and attributes each fixture's known violations to the correct skill
# group. Reuses the existing per-skill fixtures instead of planting new violation
# content. Re-run after any edit to commands/audit-architecture.md or any of the
# 5 skills' hard-rule tables.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

PROMPT=$(cat <<'EOF'
Simulate the /audit-architecture command on the combined input below, which contains
five separate files. Framework is FastAPI (confirmed by bad_fastapi.py).

For each of these 5 skills, in this order, using ONLY that skill's own "Hard rules —
always flag as violations" table, review the file(s) below and output a section:

## <skill-name>
VIOLATION: <short rule name from the table>

One line per hard-rule violation found in ANY of the files below; if a skill finds
none, output NONE under its header instead.

Skills and order: fastapi-architecture, backend-security, backend-caching,
backend-observability, backend-performance.

Do not output anything else: no fixes, no structural-preference notes, no prose
outside the section headers and VIOLATION/NONE lines.

EOF
for f in tests/fixtures/fastapi/bad_fastapi.py \
         tests/fixtures/backend-security/bad_security.py \
         tests/fixtures/backend-caching/bad_caching.py \
         tests/fixtures/backend-observability/bad_observability.py \
         tests/fixtures/backend-performance/bad_performance.py; do
  echo "--- file: $f ---"
  cat "$ROOT/$f"
done
)

OUTPUT=$(echo "$PROMPT" | claude -p --plugin-dir "$ROOT" --permission-mode bypassPermissions)
echo "$OUTPUT"
echo "---"

section() {
  awk -v s="## $1" 'BEGIN{f=0} $0==s{f=1;next} /^## /{if(f)exit} f{print}' <<< "$OUTPUT"
}

FAIL=0
check_in() {
  local skill="$1" pattern="$2" desc="$3"
  if ! grep -qiE "$pattern" <<< "$(section "$skill")"; then
    echo "MISSING in $skill: $desc"
    FAIL=1
  fi
}

check_in "fastapi-architecture" "on_event|lifespan"                       "deprecated @app.on_event startup/shutdown"
check_in "fastapi-architecture" "requests\.get|blocking"                  "blocking requests.get() inside async def"
check_in "fastapi-architecture" "bare|except"                             "bare except around route body"
check_in "fastapi-architecture" "pool_size|max_overflow|pool.*default"    "pool_size/max_overflow left at defaults"
check_in "fastapi-architecture" "n\+1|selectinload|joinedload"            "N+1 query pattern instead of eager loading"
check_in "fastapi-architecture" "response_model"                          "missing response_model / full ORM row serialized"

check_in "backend-security" "cors|wildcard|allow_origins"       "wildcard CORS origin with credentials"
check_in "backend-security" "secret|hardcoded"                  "hardcoded JWT secret"
check_in "backend-security" "extra|forbid|role|privileged"      "unforbidden extra fields / client-bound role"
check_in "backend-security" "long-lived|refresh|365"            "long-lived token used as client-side session token"
check_in "backend-security" "permission|inline|admin"           "inline permission check instead of centralized"
check_in "backend-security" "sql|injection|f-string|format"     "string-formatted SQL"

check_in "backend-caching" "unscoped|shared.*key|user.*scop"    "unscoped cache key mixing user data"
check_in "backend-caching" "version|namespace"                  "unversioned/unnamespaced cache key"
check_in "backend-caching" "ttl|invalidat"                      "caching with no TTL/invalidation path"
check_in "backend-caching" "side.effect|webhook"                "caching an operation with side effects"

check_in "backend-observability" "print|unstructured|plain-text"          "print()/unstructured logging"
check_in "backend-observability" "correlation|request.id"                 "missing correlation/request ID"
check_in "backend-observability" "password|token|secret|pii|plaintext"    "secret/token/PII logged in plaintext"
check_in "backend-observability" "except|swallow|pass"                   "swallowed exception with no log line"
check_in "backend-observability" "exc_info|logger\.exception|stack.trace" "logger.error(str(e)) discards stack trace"

check_in "backend-performance" "pagination|limit|unbounded|bound" "list endpoint with no pagination/bound enforcement"
check_in "backend-performance" "client|session|reuse|pool"        "new HTTP/DB client constructed per call instead of reused"

if [ "$FAIL" -eq 0 ]; then
  echo "OK: audit-architecture correctly grouped all 23 known violations under their skill"
else
  echo "FAIL: audit-architecture missed or misattributed one or more expected violations"
  exit 1
fi
