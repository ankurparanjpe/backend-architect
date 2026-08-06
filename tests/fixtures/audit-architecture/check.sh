#!/usr/bin/env bash
# Regression check for the /audit-architecture command: confirms it dispatches to
# all 7 skills and attributes each fixture's known violations to the correct skill
# group. Reuses the existing per-skill fixtures instead of planting new violation
# content. Re-run after any edit to commands/audit-architecture.md or any of the
# 7 skills' hard-rule tables.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

PROMPT=$(cat <<'EOF'
Simulate the /audit-architecture command on the combined input below, which contains
seven separate files. Framework is FastAPI (confirmed by bad_fastapi.py).

For each of these 7 skills, in this order, using ONLY that skill's own "Hard rules —
always flag as violations" table, review the file(s) below and output a section:

## <skill-name>
VIOLATION: <short rule name from the table>

One line per hard-rule violation found in ANY of the files below; if a skill finds
none, output NONE under its header instead.

Skills and order: fastapi-architecture, backend-security, backend-caching,
backend-observability, backend-performance, resilience-patterns, testing-standards.

Do not output anything else: no fixes, no structural-preference notes, no prose
outside the section headers and VIOLATION/NONE lines.

EOF
for f in tests/fixtures/fastapi/bad_fastapi.py \
         tests/fixtures/backend-security/bad_security.py \
         tests/fixtures/backend-caching/bad_caching.py \
         tests/fixtures/backend-observability/bad_observability.py \
         tests/fixtures/backend-performance/bad_performance.py \
         tests/fixtures/resilience-patterns/bad_resilience.py \
         tests/fixtures/testing-standards/bad_testing.py; do
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

# bad_resilience.py's timeout violations must land here, not under
# backend-performance — both skills talk about the shared HTTP client, but
# reuse is performance's rule and the deadline on it is resilience's.
check_in "resilience-patterns" "timeout|deadline"                 "outbound call with no explicit timeout"
check_in "resilience-patterns" "idempoten"                        "retry on non-idempotent POST with no usable idempotency key"
check_in "resilience-patterns" "backoff|tight.loop"               "retries with no backoff"
check_in "resilience-patterns" "fail.fast|circuit|breaker"        "no fail-fast path for a repeatedly failing dependency"
check_in "resilience-patterns" "critical path|non.critical|unguarded|isolat" "non-critical call unguarded on the critical path"

# bad_testing.py's mocked-DB violation must land here, not under
# fastapi-architecture — the two skills cross-reference the same rule, and this
# is the check that catches the attribution drifting between them.
check_in "testing-standards" "integration|mock"                   "integration test mocking the boundary it tests"
check_in "testing-standards" "order|another test ran|isolat|shared.*state" "order-dependent test / shared mutable state"
check_in "testing-standards" "patch|under test|business logic"    "business logic under test patched out"
check_in "testing-standards" "contract|response shape|status"     "consumer-facing response shape unguarded"

if [ "$FAIL" -eq 0 ]; then
  echo "OK: audit-architecture correctly grouped all 32 known violations under their skill"
else
  echo "FAIL: audit-architecture missed or misattributed one or more expected violations"
  exit 1
fi
