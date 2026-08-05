---
name: backend-observability
description: >
  Cross-cutting backend observability rules that apply regardless of framework:
  structured logging, request/correlation ID propagation, what to log at service
  boundaries, secret/PII redaction in logs, log level discipline, and exception logging
  with context. Use when the work touches logging implementation, debugging a
  production issue via logs, error tracking, or setting up monitoring/tracing, in any
  backend framework (FastAPI, Django, Flask, Express, etc.) or with no framework named
  at all. This skill does not cover authentication/authorization, CORS, rate limiting,
  or secrets storage (see backend-security), nor framework-specific wiring like
  FastAPI's `Depends`/middleware surface (see fastapi-architecture). Do not use for
  generic performance or caching questions with no logging/tracing/error-tracking angle.
---

# Backend Observability

Cross-cutting observability rules for backend APIs, independent of framework. Applies
alongside framework-specific skills (fastapi-architecture, django-architecture,
flask-architecture) rather than replacing them — this skill covers *what* must be
logged/traced and how; the framework skill covers *how* to wire it in that framework.

## Scope

**Protocol scope**: these rules are written against request/response HTTP APIs (REST-style).
Where a rule names an HTTP status code, header, or URL, that's the HTTP mechanism for a
principle that generalizes across protocols — GraphQL, gRPC, and WebSocket APIs differ in
mechanism and aren't covered here.

This skill enforces two different kinds of rules:

- **Hard rules** — observability gaps that cause real incidents or leak sensitive data:
  unstructured print()/plain-text logging in production code paths, missing
  correlation/request ID propagation, secrets/PII/tokens logged, swallowed exceptions
  logged nowhere. These are flagged as violations regardless of the project's age or
  existing conventions.
- **Structural preferences** — organizational recommendations: choice of log
  aggregator/backend (ELK, Datadog, CloudWatch), exact JSON schema for log lines, where
  logging config lives. These are advisory only. If a project has an established
  convention that differs, don't flag it as a violation — note it only if asked to audit
  structure specifically.

## Structured logging

**Hard rule**: logs are structured (JSON), not plain-text `print()` or unformatted
string logging, on any code path that runs in production. A log aggregator (ELK,
Datadog, CloudWatch, etc.) needs machine-parseable fields to filter and alert on — a
plain-text line is only greppable, not queryable.

```python
# DON'T — unqueryable, no fields to filter/alert on, invisible to log aggregators
print(f"User {user_id} failed login, attempt {attempts}")

# DO — structlog, fields are queryable in any aggregator
import structlog
log = structlog.get_logger()
log.warning("login_failed", user_id=user_id, attempts=attempts)

# DO — stdlib logging + a JSON formatter works too, structlog isn't mandatory
import logging
logger = logging.getLogger(__name__)
logger.warning("login_failed", extra={"user_id": user_id, "attempts": attempts})
```

Any `print()` or bare string-interpolated log call in application/request-handling
code is a hard-rule violation. `print()` in a one-off script or local dev tool is out
of scope — this rule targets code paths that run in production.

## Correlation / request IDs

**Hard rule**: every request gets a correlation/request ID, generated (or read from an
inbound header like `X-Request-ID`) in middleware, attached to every log line emitted
while handling that request, and propagated on any outbound call to another service.
Without this, one request touching three microservices leaves three unlinked log
trails — reconstructing what happened means guessing by timestamp.

```python
# DO — FastAPI example: middleware sets it, contextvar propagates it through
# async code without threading it through every function signature
import contextvars, uuid
from starlette.middleware.base import BaseHTTPMiddleware

request_id_ctx = contextvars.ContextVar("request_id", default=None)

class RequestIDMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        request_id = request.headers.get("X-Request-ID", str(uuid.uuid4()))
        request_id_ctx.set(request_id)
        response = await call_next(request)
        response.headers["X-Request-ID"] = request_id
        return response

# propagate on outbound calls, so the downstream service continues the same trace
async def call_downstream(client, url):
    return await client.get(url, headers={"X-Request-ID": request_id_ctx.get()})
```

A logging processor/filter should inject the contextvar's value into every log record
automatically — don't rely on every call site remembering to pass `request_id=...` by
hand. This matters more in this plugin's target setups than in a monolith: a
microservice architecture has no other way to trace one user action across process
boundaries.

**Beyond HTTP headers**: the mechanism above (a header) is HTTP-specific. gRPC carries
the same correlation ID via call metadata instead of an HTTP header; when interoperating
with standard tracing tooling, prefer the W3C `traceparent` header over a custom
`X-Request-ID` for HTTP-to-HTTP propagation. The requirement is unchanged either
way — every hop carries and forwards the ID.

## What to log at boundaries

**Hard rule**: log at service boundaries — request in/out (method, path, status,
duration), outbound calls to external APIs (target, status, duration), DB errors, and
background task failures/retries. Do not log inside every function or on every
successful internal step — that's log spam, and it's an anti-pattern in the other
direction: it buries the boundary events that actually matter under noise, and it makes
DEBUG-level logs so voluminous no one enables them in production.

```python
# DON'T — logs every internal call, drowns out anything worth finding
def calculate_discount(price, user):
    logger.info("entering calculate_discount")
    tier = get_user_tier(user)
    logger.info(f"tier is {tier}")
    ...

# DO — log the boundary, not the internals
@app.middleware("http")
async def log_requests(request, call_next):
    start = time.monotonic()
    response = await call_next(request)
    logger.info(
        "request_handled",
        method=request.method, path=request.url.path,
        status=response.status_code,
        duration_ms=round((time.monotonic() - start) * 1000, 1),
    )
    return response
```

**GraphQL note**: a GraphQL API sends every operation through the same route
(`POST /graphql`), so a REST-shaped access log (method + path) reads as `POST /graphql`
for every request and tells you nothing. Log the operation name and type
(`query`/`mutation`/`subscription`) as fields instead — that's the boundary event that's
actually distinguishing for a GraphQL service.

## Never log secrets, tokens, PII, or full sensitive request bodies

**Hard rule**: never log passwords, API keys, JWTs/session tokens, credit card numbers,
or other PII (email, phone, SSN) in plaintext — and never log a full request/response
body without confirming it doesn't contain sensitive fields. This is the single
highest-impact rule in this skill: a logged secret or PII value sits in the log
aggregator, often with looser access control and longer retention than the primary
datastore, and "fix the log line" doesn't undo the exposure — the value must be
rotated (secrets) or the log line purged/redacted (PII), same as a leaked credential.

```python
# DON'T — token and password land in the log aggregator in plaintext
logger.info("login_attempt", password=data.password, body=data.dict())

# DO — log identifiers, never the sensitive value itself
logger.info("login_attempt", user_email=data.email)

# DO — if a full payload must be logged for debugging, redact known-sensitive keys first
SENSITIVE_KEYS = {"password", "token", "authorization", "ssn", "card_number"}

def redact(payload: dict) -> dict:
    return {k: ("***" if k.lower() in SENSITIVE_KEYS else v) for k, v in payload.items()}

logger.debug("request_body", body=redact(data.dict()))
```

Structured logging (JSON fields) makes this easier to enforce than plain-text —
a logging processor can redact known field names before a line is emitted, which a
free-form string interpolation can't be scanned for reliably.

## Log levels

**Hard rule**: use the level that matches the event, not one level for everything.
Everything-at-INFO buries real problems in routine noise; everything-at-ERROR trains
whoever's on call to ignore alerts because most of them aren't actionable.

| Level | Use for |
|---|---|
| `DEBUG` | Internal state useful only while actively debugging; off by default in production. |
| `INFO` | Normal operation: request handled, background job completed, boundary events. |
| `WARNING` | Unexpected but handled: retry succeeded, deprecated input, fallback path taken. |
| `ERROR` | An operation failed and something (a request, a task) did not complete as intended. |
| `CRITICAL` | The service itself is compromised: can't reach its DB, out of disk, cannot start. |

## Exception logging

**Hard rule**: log an exception with its stack trace and surrounding context at the
point it's caught, not just `except Exception: pass` or a re-raise with no log line.
An exception that's caught and silently swallowed leaves no trace it ever happened —
the bug report becomes "users say X sometimes doesn't work" with nothing to search for.
This is the same underlying anti-pattern as fastapi-architecture's bare-except rule
(catching bare `Exception` around a route body) — that skill covers the *catching*
side of it; this rule covers the *logging* side once you do catch something.

```python
# DON'T — failure is invisible, no log, no trace
try:
    send_webhook(payload)
except Exception:
    pass

# DO — logged with stack trace and enough context to act on
try:
    send_webhook(payload)
except Exception:
    logger.exception("webhook_send_failed", webhook_url=url, payload_id=payload.id)
```

`logger.exception(...)` (or `logger.error(..., exc_info=True)`) captures the stack
trace automatically — use it instead of `logger.error(str(e))`, which discards the
traceback and leaves only the exception's message.

## Advisory: aggregator/backend choice

Which log aggregator or backend a project uses (ELK, Datadog, CloudWatch, Splunk,
Loki, etc.) is a project/infrastructure decision, not something this skill enforces.
The skill enforces the *practice* — logs are structured, correlated across a request,
and boundary-scoped — which is portable across any backend. Don't flag a project's
choice of aggregator as a violation; note it only if asked to audit tooling
specifically.

## Anti-patterns

### Hard rules — always flag as violations

| Anti-pattern | Why it's wrong | Fix |
|---|---|---|
| `print()` or plain-text string logging in a production code path | Unqueryable in any log aggregator; no fields to filter/alert on. | Structured logging (structlog or stdlib + JSON formatter). |
| No correlation/request ID generated or propagated | One request across services leaves unlinked, unreconstructable log trails. | Middleware sets/reads the ID; contextvar propagates it through async code and outbound calls. |
| Logging inside every function / every internal step | Log spam — buries boundary events that matter, makes DEBUG unusable in production. | Log at boundaries only: request in/out, external calls, DB errors, task failures. |
| Secret, token, password, or PII logged in plaintext | Log aggregator often has looser access control and longer retention than the primary datastore. | Never log the raw value; log an identifier, and redact known-sensitive fields if a full payload must be logged. |
| Full request/response body logged without checking for sensitive fields | Same exposure as above, via an indirect path. | Redact known-sensitive keys before logging, or log only the fields actually needed. |
| Everything logged at INFO (or everything at ERROR) | Buries real problems in noise, or trains on-call to ignore alerts. | Match level to event severity per the DEBUG–CRITICAL table. |
| `except Exception: pass` (or bare re-raise) with no log line | Failure is invisible — no trace it happened, nothing to search for later. | `logger.exception(...)` at the point of catch, with context. |
| `logger.error(str(e))` instead of `logger.exception(...)` / `exc_info=True` | Discards the stack trace, leaves only the exception's message. | Use `logger.exception(...)` or pass `exc_info=True`. |

### Structural preferences — advisory, respect existing convention

| Pattern | Rationale | If the project uses a different convention |
|---|---|---|
| Choice of log aggregator/backend (ELK, Datadog, CloudWatch, Loki, etc.) | Infrastructure decision, not a correctness rule. | Don't flag; note only if asked to audit tooling specifically. |
| Exact JSON schema/field naming for log lines | Consistency matters more than the specific names chosen. | Note the project's existing schema and follow it, don't impose a different one. |
| Where logging configuration lives (dedicated `logging.py` vs. inline setup) | Organizational preference. | Follow existing project structure. |
