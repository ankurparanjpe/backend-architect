---
name: backend-security
description: >
  Cross-cutting backend security rules that apply regardless of framework: CORS
  configuration, rate limiting, secrets/env handling, security headers, input validation
  at the boundary, and auth patterns beyond JWT decode (token lifetimes, refresh flow,
  permission checks). Use when the work touches authentication/authorization, CORS,
  rate limiting, secrets or environment variables, security headers, or request/input
  validation, in any backend framework (FastAPI, Django, Flask, Express, etc.) or with no
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

This skill enforces two different kinds of rules:

- **Hard rules** — security issues that are exploitable or fail open: wildcard CORS in
  production, no rate limiting on public endpoints, hardcoded secrets, missing security
  headers, trusting client input past the boundary, long-lived tokens stored client-side.
  These are flagged as violations regardless of the project's age or existing
  conventions.
- **Structural preferences** — organizational recommendations: where permission checks
  live, how auth dependencies are composed, naming of security-related config. These are
  advisory only. If a project has an established convention that differs, don't flag it
  as a violation — note it only if asked to audit structure specifically.

## CORS

**Hard rule**: explicit `allow_origins` list in production. Never `*` (wildcard) once
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

- `.env` files are for **local development only** — never committed (`.gitignore`
  it), and never the source of truth in staging/production, where a secret manager or
  the platform's native secret injection (e.g. ECS task secrets, Kubernetes Secrets)
  should be used instead.
- Rotate a secret immediately if it's ever found in a commit, even a since-reverted one
  — git history retains it.

## Security headers

**Hard rule**: set standard security headers via middleware, not left to the framework's
defaults (most frameworks set none of these by default).

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

## Anti-patterns

### Hard rules — always flag as violations

| Anti-pattern | Why it's wrong | Fix |
|---|---|---|
| `allow_origins=["*"]` with `allow_credentials=True` | Any origin can make authenticated requests on the user's behalf. | Explicit origin allowlist from config. |
| Public endpoint with no rate limiting (gateway or app-level) | Open to credential stuffing / resource exhaustion. | Gateway-level limiter, or app middleware if none exists. |
| Hardcoded secret/API key/credential in source | Permanent in git history once committed. | Env var or secret manager; rotate if ever committed. |
| `.env` committed to version control | Same as above — leaks whatever it contains. | `.gitignore` it; use a secret manager in staging/prod. |
| No security headers (HSTS, X-Content-Type-Options, X-Frame-Options) set anywhere | Browser has no defense-in-depth if another layer fails. | Global middleware setting standard headers on every response. |
| Input schema with `extra="allow"` (or framework default that ignores unknown fields) on a write endpoint | Silently accepts fields the client shouldn't be able to set. | `extra="forbid"` (or equivalent) at the boundary. |
| Privileged field (`role`, `is_admin`, `user_id`) present on a client-writable input schema | Client can set its own privilege level. | Never bind privileged fields from request body; set server-side from auth context. |
| Long-lived JWT used directly as a client-side session token | No revocation path short of rotating the signing key. | Short-lived access token + separate, storage-backed refresh token. |
| Permission check (`if user.role != "admin"`) repeated inline per route | Drifts — permission model changes don't propagate to every check. | Centralize via a dependency/middleware every protected route goes through. |
| String-formatted SQL with user input (`f"SELECT * FROM x WHERE id={id}"`) | SQL injection. | Parameterized queries / ORM query builder. |
| Rendering unescaped user input into HTML | XSS. | Auto-escaping template engine, or explicit escaping at the sink. |

### Structural preferences — advisory, respect existing convention

| Pattern | Rationale | If the project uses a different convention |
|---|---|---|
| Permission checks composed via dependency injection vs. a decorator-based permission system | Keeps checks colocated with route composition, reuses the same DI graph as other route deps | Note it as "this project uses decorator-based permissions" — not a violation if consistently applied |
| One `SecurityConfig`/`AuthConfig` settings class vs. security-related env vars scattered across the app | Clear ownership of security-relevant config | Note only if asked to audit config structure specifically |
