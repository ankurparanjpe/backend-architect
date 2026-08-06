---
name: backend-security
description: >
  Cross-cutting backend security rules that apply regardless of framework: CORS
  configuration, rate limiting, secrets/env handling, security headers, input validation
  at the boundary, error-response standardization (consistent error schema, correct HTTP
  status codes, no internal detail leaked to clients), and auth patterns beyond JWT decode
  (token lifetimes, refresh flow, permission checks). Use when the work touches
  authentication/authorization, CORS, rate limiting, secrets or environment variables,
  security headers, request/input validation, or the shape and status codes of error
  responses returned to clients, in any backend framework (FastAPI, Django, Flask, Express, etc.) or with no
  framework named at all. This skill does not cover framework-specific implementation
  details (e.g. FastAPI's `Depends`/`Annotated` wiring, Django's `SECURE_*` settings
  surface) — pair it with the matching framework skill (fastapi-architecture,
  django-architecture, flask-architecture) for those. Do not use for generic performance,
  caching, or observability questions with no security angle.
---

# Backend Security

Cross-cutting security rules for backend APIs, independent of framework. Applies
alongside framework-specific skills (fastapi-architecture, django-architecture,
flask-architecture) rather than replacing them — this skill covers *what* the security
posture must be; the framework skill covers *how* to wire it in that framework.

## Scope

**Protocol scope**: these rules are written against request/response HTTP APIs (REST-style).
Where a rule names an HTTP status code, header, or URL, that's the HTTP mechanism for a
principle that generalizes across protocols — GraphQL, gRPC, and WebSocket APIs differ in
mechanism and aren't covered here.

This skill enforces two different kinds of rules:

- **Hard rules** — security issues that are exploitable or fail open: wildcard CORS in
  production, no rate limiting on public endpoints, hardcoded secrets, missing security
  headers, trusting client input past the boundary, leaking internal detail in error
  responses, long-lived tokens stored client-side. These are flagged as violations
  regardless of the project's age or existing conventions.
- **Structural preferences** — organizational recommendations: where permission checks
  live, how auth dependencies are composed, the exact field names in the error schema,
  naming of security-related config. These are
  advisory only. If a project has an established convention that differs, don't flag it
  as a violation — note it only if asked to audit structure specifically.

## CORS

**Hard rule** (HTTP/REST — CORS is a browser enforcement mechanism scoped to HTTP): explicit `allow_origins` list in production. Never `*` (wildcard) once
credentials, cookies, or auth headers are involved — a wildcard origin combined with
`allow_credentials=True` lets any site read authenticated responses on behalf of a
logged-in user.

```python
# DON'T — any site can call this API with the user's cookies/credentials
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
)

# DO — explicit allowlist, sourced from config/env, not hardcoded per-environment
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.CORS_ALLOWED_ORIGINS,  # e.g. ["https://app.example.com"]
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE"],
    allow_headers=["Authorization", "Content-Type"],
)
```

`*` is acceptable only for a fully public, unauthenticated, read-only API with no
credentials — and even then, prefer an explicit list once the set of consumers is known.

## Rate limiting

**Hard rule**: every public-facing endpoint sits behind rate limiting, at the gateway
(load balancer, API gateway, reverse proxy) or in application middleware. Relying on
"nothing" — no gateway limit and no app-level limit — is a hard-rule violation, not a
missing nice-to-have: it leaves auth endpoints open to credential stuffing and any
endpoint open to trivial resource exhaustion.

```python
# DO — app-level limiter when there's no gateway/WAF in front
from slowapi import Limiter
from slowapi.util import get_remote_address

limiter = Limiter(key_func=get_remote_address)

@router.post("/login")
@limiter.limit("5/minute")
async def login(data: LoginIn):
    ...
```

Prefer gateway-level limiting (nginx, Cloudflare, API Gateway, Kong) when one already
sits in front of the service — it protects the process before a request even reaches
app code, and one config point covers every route. Reach for app-level middleware only
when no gateway exists or when a route needs a materially different limit than the
gateway default (e.g. login/signup/password-reset stricter than general API traffic).

## Secrets management

**Hard rule**: secrets (API keys, DB credentials, JWT signing keys, third-party tokens)
come from environment variables or a secret manager (Vault, AWS Secrets Manager, GCP
Secret Manager), never hardcoded in source. A hardcoded secret is a violation even in
a "temporary" or "just for testing" commit — it ends up in git history permanently.

```python
# DON'T — flag as a hard violation regardless of context
JWT_SECRET = "super-secret-key-123"
STRIPE_API_KEY = "sk_live_abc123..."

# DO
class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env")
    JWT_SECRET: str
    STRIPE_API_KEY: str

settings = Settings()
```

- `.env` files hold real values and are for **local development only** — never
  committed (`.gitignore` it), and never the source of truth in staging/production,
  where a secret manager or the platform's native secret injection (e.g. ECS task
  secrets, Kubernetes Secrets) should be used instead.
- A committed **`.env.example` / `.env.template` is correct practice, not a violation.**
  It documents the config contract — which variables the app requires — using
  placeholder values only, with a header stating that the file is committed and holds no
  real secrets. Flag it only when a real credential has actually been pasted into it: a
  placeholder or local-only dev value (`POSTGRES_PASSWORD=changeme`) is not a leak, while
  a live API key or a production DSN in the same file is the same hard violation as any
  other hardcoded secret.
- Rotate a secret immediately if it's ever found in a commit, even a since-reverted one
  — git history retains it.

## Security headers

**Hard rule** (HTTP/REST): set standard security headers via middleware, not left to the
framework's defaults (most frameworks set none of these by default).

| Header | Purpose |
|---|---|
| `Strict-Transport-Security` | Forces HTTPS on repeat visits; prevents protocol downgrade attacks. |
| `X-Content-Type-Options: nosniff` | Stops browsers from MIME-sniffing a response into executing as a different content type. |
| `X-Frame-Options: DENY` (or `Content-Security-Policy: frame-ancestors 'none'`) | Prevents clickjacking via iframe embedding. |
| `Content-Security-Policy` | Restricts what scripts/styles/resources a page may load. |
| `Referrer-Policy: strict-origin-when-cross-origin` | Limits referrer leakage to third parties. |

```python
# DO — one middleware, applied to every response
@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["Strict-Transport-Security"] = "max-age=63072000; includeSubDomains"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    return response
```

Don't hand-roll this per route — one middleware applied globally, so a new endpoint
can't accidentally ship without headers.

## Input validation

**Hard rule**: validate at the trust boundary (the first point untrusted data enters the
system), and reject anything unexpected rather than silently dropping or coercing it.
"Use Pydantic" is necessary but not sufficient — validation must also:

- **Reject unexpected fields**, not silently ignore them. A client sending
  `{"role": "admin"}` on a signup payload should 422, not get silently stripped and
  proceed — silent stripping hides mass-assignment bugs from the client but doesn't
  prevent a field that *is* bound from being attacker-controlled.

  ```python
  class SignupIn(BaseModel):
      model_config = ConfigDict(extra="forbid")  # DO — reject unknown fields
      email: EmailStr
      password: str
  ```

- **Never bind privileged fields from client input.** `role`, `is_admin`,
  `user_id` (when it should come from the auth token, not the body) must not appear on
  an input schema at all — set them server-side from the authenticated identity.

  ```python
  # DON'T — client controls their own role
  class UserUpdateIn(BaseModel):
      name: str
      role: str  # attacker sends {"role": "admin"}

  # DO — role is never client-settable
  class UserUpdateIn(BaseModel):
      name: str
  ```

- **Sanitize where output context requires it** — validating shape/type isn't the same
  as sanitizing for the sink. A validated `str` field rendered into HTML still needs
  escaping (auto-escaping template engine, or explicit escape); a validated `str` used
  in a raw SQL string still needs parameterization, not just a length check.

## Error responses

The inbound side of the trust boundary is [input validation](#input-validation); this is the
outbound side. Errors are part of the API contract, and an error path that's improvised per
route is both unparseable for clients and the most common way internal detail escapes.

### One error schema, every endpoint

**Hard rule**: all endpoints return errors in the same shape. Ad-hoc, per-route error
bodies are a violation, not a style inconsistency — a client can't write one error handler
against a contract that changes shape depending on which route failed, so it ends up
either string-matching on messages or ignoring error bodies entirely.

```python
# DON'T — three routes, three shapes, no client can parse this generically
@router.post("/login")
async def login(...):
    return {"error": "invalid credentials"}          # bare string under "error"

@router.get("/posts/{post_id}")
async def get_post(...):
    return {"errors": [{"detail": "not found"}]}     # list under "errors"

@router.delete("/posts/{post_id}")
async def delete_post(...):
    return {"message": "forbidden", "ok": False}     # something else again

# DO — one envelope, defined once, produced by one handler
class ErrorBody(BaseModel):
    code: str        # stable, machine-readable: "invalid_credentials", "post_not_found"
    message: str     # human-readable, safe to show a user

class ErrorResponse(BaseModel):
    error: ErrorBody
```

The `code` field is what clients branch on, so it has to be stable and machine-readable —
a code that's really a prose sentence forces clients back to string-matching on `message`,
which then can't be reworded without breaking them.

Produce the envelope in **one place** — a global exception handler / error middleware that
maps the application's exception types onto it — not by hand-constructing the dict in every
route. Per-route construction is what lets the shape drift in the first place, and it's
also what lets an unmapped exception fall through to the framework's own default error
body, which is a different shape again.

### Status codes carry the failure

**Hard rule** (HTTP/REST status-code convention): the HTTP status code communicates the failure. Returning `200 OK` with a
failure described in the body is a hard violation — every layer between the service and the
client (load balancers, proxies, retry logic, HTTP client libraries, error-rate monitoring,
alerting) reads the status code, so a failure hidden in a `200` body is invisible to all of
them. Error rates read as zero while users see failures.

```python
# DON'T — the request failed; the status says it succeeded
@router.post("/login")
async def login(data: LoginIn):
    user = await authenticate(data)
    if not user:
        return {"success": False, "error": "invalid credentials"}   # HTTP 200

# DO — status code and body agree
@router.post("/login")
async def login(data: LoginIn):
    user = await authenticate(data)
    if not user:
        raise InvalidCredentials()   # → 401, mapped to the error envelope by the handler
```

| Status | Use when | Not when |
|---|---|---|
| `400 Bad Request` | The request is malformed or semantically invalid in a way schema validation doesn't cover (e.g. `end_date` before `start_date`). | The body simply failed schema validation — that's `422`. |
| `401 Unauthorized` | No credentials, or credentials that are missing/expired/invalid. The caller is **unauthenticated**. | The caller is known but not allowed — that's `403`. |
| `403 Forbidden` | Credentials are valid but the caller lacks permission for this action. Re-authenticating won't help. | The caller isn't authenticated at all — that's `401`. |
| `404 Not Found` | The resource doesn't exist — or exists but the caller must not learn that it does (see below). | A validation failure on a resource that does exist. |
| `422 Unprocessable Entity` | Request body/params failed schema validation (wrong type, missing required field, constraint violated). | A business-rule failure on a well-formed body — that's `400` or a domain-specific `409`. |
| `500 Internal Server Error` | An unhandled/unexpected server-side fault. Always accompanied by a logged stack trace server-side. | The client sent something wrong — never return `500` for a client error, it makes real faults unfindable in monitoring. |

`401` vs `403` is the pair that gets confused most, and getting it wrong breaks clients:
a client that sees `401` will try to refresh its token and retry, which is correct for
expired credentials and a pointless retry loop for a permission failure.

Prefer `404` over `403` when the existence of the resource is itself privileged — a `403`
on `/users/{id}/documents/{doc_id}` confirms that `doc_id` exists, which is an enumeration
oracle. Pick one behaviour and apply it consistently; alternating between `403` and `404`
for the same class of resource leaks the same information through the difference.

**GraphQL note**: this rule is written for REST/HTTP-status-per-outcome APIs, and GraphQL
doesn't map onto it cleanly. Two things vary. *Where* the failure happens: a request that
fails before execution begins — a parse error, a query that doesn't validate against the
schema — may legitimately carry a non-200 status, while a failure *during* execution (a
resolver raising, a business rule rejecting) is normally reported as `200` with the failure
in the `errors` array. And *how the response is negotiated*: under the legacy
`application/json` media type most servers answer `200` for both cases, whereas the
`application/graphql-response+json` media type in the GraphQL-over-HTTP specification does
use status codes to distinguish them. So don't assume one universal mapping — check what
the server and media type in front of you actually do.

What transfers is the principle, not the mechanism: a failure has to be signalled
explicitly rather than dressed up as a success. In GraphQL the primary carrier is the
`errors` array, so the violation worth flagging is a resolver that swallows a failure and
returns a null field with nothing in `errors` — not the `200` itself.

**gRPC note**: gRPC has no HTTP status codes in this sense — it returns its own status
code set (`OK`, `NOT_FOUND`, `PERMISSION_DENIED`, `UNAVAILABLE`, `DEADLINE_EXCEEDED`,
etc.) in the response trailer. Map failures to the closest gRPC status rather than
reusing HTTP's 4xx/5xx numbering; see resilience-patterns § Timeouts on every external
call for the matching note on gRPC deadlines as the equivalent of an HTTP timeout.

### Never leak internal detail

**Hard rule**: error responses returned to clients in production must never contain stack
traces, raw exception strings, database error text, SQL fragments, file paths, or internal
hostnames. This is a correctness bug with a security consequence, not a polish issue — those
strings are reconnaissance: a leaked `psycopg2` error names tables and columns, a stack
trace names internal modules and library versions, a file path names the deploy layout.

```python
# DON'T — hands the client the internals of the failure
@router.get("/orders/{order_id}")
async def get_order(order_id: str):
    try:
        return await service.get_order(order_id)
    except Exception as exc:
        return {"error": str(exc)}                    # DB error text, SQL, table names
        # or worse:
        # return {"error": traceback.format_exc()}

# DO — full detail to the logs, a generic message plus a correlation id to the client
@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception):
    logger.exception("unhandled error", extra={"path": request.url.path})
    return JSONResponse(
        status_code=500,
        content={"error": {"code": "internal_error", "message": "An internal error occurred."}},
    )
```

The detail isn't discarded — it goes to the logs, where it's needed for debugging and where
only operators can read it. Return a correlation/request id in the error body so a user
report can be tied back to the logged trace without the trace itself crossing the boundary;
see backend-observability for the request-id propagation and log-redaction rules that make
this work.

Two related traps:

- **Debug mode in production.** A framework's debug/development mode renders stack traces
  into HTTP responses by design. Debug must be driven by config and off in production —
  a debug flag defaulting to `True` is the same violation delivered by the framework.
- **Different messages for the same failure class.** "user not found" vs "wrong password"
  on a login endpoint is a user-enumeration oracle. Both must return the same generic
  credentials error with the same status code; the distinction goes to the logs only.

### Error schema field naming (structural preference — advisory)

> Advisory, not a hard rule — see [Scope](#scope).

Whether the envelope is `{"error": {...}}`, `{"errors": [...]}`, `{"detail": ...}`, or a
standard like RFC 9457 `application/problem+json` is a project convention, and there's no
single right answer to prescribe. Frameworks also come with their own default (FastAPI's
`HTTPException` produces `{"detail": ...}`), and adopting that default is a legitimate
choice.

The hard rule is **be consistent** — one shape, everywhere, including framework-generated
errors like validation failures, which need an exception handler to be reshaped into the
project's envelope rather than being left as the odd one out. If a project already has an
established error shape, don't flag it as a violation for not matching the `{"error":
{"code", "message"}}` example above; flag only endpoints that deviate from the project's
own shape.

## Auth patterns beyond JWT decode

**Hard rule**: short-lived access tokens (minutes, not days) + a separate long-lived
refresh token, with the refresh token issued via a dedicated endpoint and stored
server-trackable (so it can be revoked). Never issue a long-lived token for direct
client-side use — a stolen long-lived access token is valid for as long as it was
issued for, with no revocation path short of rotating the signing key for everyone.

```python
# DO
ACCESS_TOKEN_EXPIRE_MINUTES = 15
REFRESH_TOKEN_EXPIRE_DAYS = 30

def create_access_token(user_id: str) -> str:
    return jwt.encode(
        {"sub": user_id, "exp": datetime.utcnow() + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)},
        settings.JWT_SECRET,
        algorithm="HS256",
    )

# refresh tokens are opaque + stored (DB/Redis), not just a longer-lived JWT —
# storage is what makes revocation possible
def create_refresh_token(user_id: str) -> str:
    token = secrets.token_urlsafe(32)
    store_refresh_token(token, user_id, expires_in=timedelta(days=REFRESH_TOKEN_EXPIRE_DAYS))
    return token
```

**Hard rule**: permission checks live in a dependency/middleware layer that every
protected route goes through, not as scattered inline `if user.role != "admin":` checks
repeated per route. Scattered checks drift — one route gets updated when the permission
model changes, another doesn't, and the gap is a silent authorization bug.

```python
# DON'T — repeated, drifts over time
@router.delete("/posts/{post_id}")
async def delete_post(post_id: UUID, user: User = Depends(get_current_user)):
    if user.role != "admin" and user.id != post.owner_id:
        raise HTTPException(403)
    ...

# DO — permission logic lives once, composed via dependency injection
def require_post_owner_or_admin(
    post: Annotated[Post, Depends(valid_post_id)],
    user: Annotated[User, Depends(get_current_user)],
) -> Post:
    if user.role != "admin" and user.id != post.owner_id:
        raise HTTPException(403)
    return post

@router.delete("/posts/{post_id}")
async def delete_post(post: Annotated[Post, Depends(require_post_owner_or_admin)]):
    ...
```

**GraphQL note**: a GraphQL API typically exposes one endpoint (`POST /graphql`), so
route/middleware-level authorization checks nothing useful — every operation, whatever
its permissions, passes through the same route. Authorization must be enforced at the
resolver/field level instead (a directive like `@auth`, or a check at the top of each
resolver), the GraphQL equivalent of the dependency layer above.

## Anti-patterns

### Hard rules — always flag as violations

| Anti-pattern | Why it's wrong | Fix |
|---|---|---|
| `allow_origins=["*"]` with `allow_credentials=True` | Any origin can make authenticated requests on the user's behalf. | Explicit origin allowlist from config. |
| Public endpoint with no rate limiting (gateway or app-level) | Open to credential stuffing / resource exhaustion. | Gateway-level limiter, or app middleware if none exists. |
| Hardcoded secret/API key/credential in source | Permanent in git history once committed. | Env var or secret manager; rotate if ever committed. |
| A real `.env` (holding actual credentials) committed to version control | Same as above — leaks whatever it contains, permanently. | `.gitignore` it; use a secret manager in staging/prod. **Not** a violation: a committed `.env.example`/`.env.template` carrying placeholder values only — that's the documented config contract. Flag that file only if a real credential was pasted into it. |
| No security headers (HSTS, X-Content-Type-Options, X-Frame-Options) set anywhere | Browser has no defense-in-depth if another layer fails. | Global middleware setting standard headers on every response. |
| Input schema with `extra="allow"` (or framework default that ignores unknown fields) on a write endpoint | Silently accepts fields the client shouldn't be able to set. | `extra="forbid"` (or equivalent) at the boundary. |
| Privileged field (`role`, `is_admin`, `user_id`) present on a client-writable input schema | Client can set its own privilege level. | Never bind privileged fields from request body; set server-side from auth context. |
| Long-lived JWT used directly as a client-side session token | No revocation path short of rotating the signing key. | Short-lived access token + separate, storage-backed refresh token. |
| Permission check (`if user.role != "admin"`) repeated inline per route | Drifts — permission model changes don't propagate to every check. | Centralize via a dependency/middleware every protected route goes through. |
| String-formatted SQL with user input (`f"SELECT * FROM x WHERE id={id}"`) | SQL injection. | Parameterized queries / ORM query builder. |
| Rendering unescaped user input into HTML | XSS. | Auto-escaping template engine, or explicit escaping at the sink. |
| Error bodies with a different shape per route (`{"error": "..."}` here, `{"errors": [...]}` or `{"message": ..., "ok": false}` there) | No client can write one error handler against a contract that changes shape per route; it falls back to string-matching or ignoring error bodies. | One error schema for the whole API, emitted by a single exception handler / error middleware. |
| Failure returned as `200 OK` with the error in the body (`{"success": false, ...}`) | Proxies, retries, HTTP clients, and error-rate monitoring all read the status code — a failure hidden in a `200` is invisible to every one of them. | Raise/return the correct 4xx/5xx status; body and status must agree. |
| `500` for a client error, or `4xx` for a server fault | Real faults become unfindable in monitoring, and clients retry things that will never succeed. | Map the failure to the right code — `401` unauthenticated, `403` unauthorized, `422` schema validation, `400` other invalid request, `500` server fault only. |
| `403` where the resource's existence is itself privileged | Confirms the resource exists — an enumeration oracle. | `404` for privileged resources, applied consistently across that resource class. |
| Stack trace, `str(exc)`, DB error text, SQL, or file path returned in an error response | Reconnaissance: names tables, columns, internal modules, library versions, deploy layout. | Log full detail server-side; return a generic message plus a correlation id. |
| Debug/development mode enabled in production (or a debug flag defaulting to `True`) | The framework renders stack traces into HTTP responses by design. | Drive debug from config; off in production, default `False`. |
| Distinguishable error messages for the same failure class ("user not found" vs "wrong password") | User-enumeration oracle. | One generic message and status for the class; the distinction goes to the logs only. |

### Structural preferences — advisory, respect existing convention

| Pattern | Rationale | If the project uses a different convention |
|---|---|---|
| Permission checks composed via dependency injection vs. a decorator-based permission system | Keeps checks colocated with route composition, reuses the same DI graph as other route deps | Note it as "this project uses decorator-based permissions" — not a violation if consistently applied |
| One `SecurityConfig`/`AuthConfig` settings class vs. security-related env vars scattered across the app | Clear ownership of security-relevant config | Note only if asked to audit config structure specifically |
| Error envelope field naming — `{"error": {...}}` vs `{"errors": [...]}` vs `{"detail": ...}` vs RFC 9457 `problem+json` | A single machine-readable `code` plus a human-readable `message` covers both client branching and display | Adopt the project's existing shape (including a framework default like FastAPI's `{"detail": ...}`); flag only endpoints deviating from *that* shape, never the shape itself |
