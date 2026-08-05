---
name: backend-caching
description: >
  Cross-cutting backend caching rules that apply regardless of framework: cache
  layering (HTTP-level, application-level, dependency-level), cache key design and
  versioning, invalidation strategy, and safe scoping of cached data. Use when the work
  touches caching implementation — Redis or in-memory caching, response caching
  (ETags/Cache-Control), cache invalidation, or memoization of expensive computations
  (DB aggregations, embeddings, external API responses) — in any backend framework
  (FastAPI, Django, Flask, Express, etc.) or with no framework named at all. This skill
  does not cover authentication/authorization, CORS, rate limiting, or secrets storage
  (see backend-security), nor structured logging/tracing (see backend-observability),
  nor framework-specific wiring like FastAPI's per-request `Depends()` caching mechanics
  (see fastapi-architecture). Do not use for generic performance tuning or database
  query optimization with no caching angle.
---

# Backend Caching

Cross-cutting caching rules for backend APIs, independent of framework. Applies
alongside framework-specific skills (fastapi-architecture, django-architecture,
flask-architecture) rather than replacing them — this skill covers *what* the caching
practice must be; the framework skill covers *how* to wire it in that framework.

## Scope

**Protocol scope**: these rules are written against request/response HTTP APIs (REST-style).
Where a rule names an HTTP status code, header, or URL, that's the HTTP mechanism for a
principle that generalizes across protocols — GraphQL, gRPC, and WebSocket APIs differ in
mechanism and aren't covered here.

This skill enforces two different kinds of rules:

- **Hard rules** — caching mistakes that cause silent correctness or security bugs:
  unversioned/unnamespaced cache keys that serve stale data across a schema or logic
  change, caching added with no invalidation path (no TTL, no explicit invalidation),
  caching responses/operations with side effects, and cache keys that leak
  user-scoped or auth-sensitive data across users due to insufficient key scoping.
  These are flagged as violations regardless of the project's age or existing
  conventions.
- **Structural preferences** — organizational recommendations: choice of cache backend
  (Redis vs. Memcached vs. an in-memory dict for single-instance apps), and TTL
  duration values. These are advisory only — backend choice and freshness windows are
  project/business decisions this skill does not prescribe. If a project has an
  established convention that differs, don't flag it as a violation — note it only if
  asked to audit structure specifically.

## Cache layering

Caching applies at three distinct layers — pick the layer that matches what's actually
expensive, not just the one that's most familiar:

- **HTTP-level** (REST/HTTP caching semantics) — `ETag`/`Cache-Control` for cacheable
  `GET` responses, so the client or an intermediary (CDN, reverse proxy) can skip the
  round trip to your service entirely.

  ```python
  # DO — conditional GET, client/CDN can skip re-fetching unchanged data
  @router.get("/products/{product_id}")
  async def get_product(product_id: UUID, response: Response):
      product = await fetch_product(product_id)
      response.headers["Cache-Control"] = "public, max-age=60"
      response.headers["ETag"] = product.etag
      return product
  ```

- **Application-level** — Redis (or another shared cache) for computed results that
  are expensive to produce and reusable across requests/users: DB aggregations,
  embeddings, third-party API responses.

  ```python
  # DO — cache an expensive aggregation, not the raw rows
  async def get_monthly_revenue(org_id: str) -> Decimal:
      key = f"v2:org:{org_id}:monthly_revenue"
      cached = await redis.get(key)
      if cached is not None:
          return Decimal(cached)
      value = await compute_monthly_revenue(org_id)  # expensive DB aggregation
      await redis.set(key, str(value), ex=300)
      return value
  ```

- **Dependency-level** — reuse a value already computed earlier in the *same* request
  instead of recomputing it. In FastAPI, `Depends()` already caches by default within
  one request (same dependency, same request → the callable runs once); don't
  hand-roll a second cache on top of that for the same value.

  ```python
  # DO — FastAPI resolves get_current_user once per request even if multiple
  # route dependencies declare it; no extra caching needed for this layer
  async def get_current_user(token: str = Depends(oauth2_scheme)) -> User:
      return await decode_and_load_user(token)

  async def require_admin(user: User = Depends(get_current_user)) -> User:
      if not user.is_admin:
          raise HTTPException(403)
      return user
  ```

Don't reach for Redis to solve a dependency-level problem (recomputing something
already available in-request), and don't reach for a dependency cache to solve an
application-level problem (a value that should be shared *across* requests/users).

## Cache key design

**Hard rule**: cache keys are versioned/namespaced (`v2:org:{id}:...`, not
`org:{id}:...`), so a schema or logic change to what a key represents doesn't silently
serve stale data shaped for the old logic under an old key. This is a hard-rule
violation, not a style nitpick, when invalidation of that key depends on the version
segment changing — an unversioned key with no other invalidation path means the only
way to force a refresh after a logic change is a manual cache flush, which gets
forgotten.

```python
# DON'T — no version segment; changing compute_monthly_revenue's logic silently
# serves results shaped for the old logic to anyone hitting the still-warm key
key = f"org:{org_id}:monthly_revenue"

# DO — bump the version segment when the value's shape or computation changes;
# old-version keys simply expire unread, no manual flush required
key = f"v2:org:{org_id}:monthly_revenue"
```

Namespacing (`org:{id}:...` vs. a bare `{id}`) also prevents key collisions between
unrelated cached values that happen to share an identifier (e.g. an `org_id` and a
`user_id` that are both UUIDs).

## Invalidation strategy

**Hard rule**: an invalidation plan exists *before* caching is added — either a TTL
short enough that staleness is acceptable, or an explicit invalidation path (delete/
update the key when the underlying data changes), or both. Caching added with neither
is a hard-rule violation: silently served stale data is a correctness bug, not a
missing nice-to-have, and it's a materially worse failure mode than the slow query the
cache was added to avoid — a slow response is visible; stale data served fast is not.

```python
# DON'T — cached with no TTL and nothing ever invalidates it; the value is
# correct only until the underlying row changes, and nothing here notices
await redis.set(f"v2:user:{user_id}:profile", json.dumps(profile))

# DO — TTL bounds the staleness window
await redis.set(f"v2:user:{user_id}:profile", json.dumps(profile), ex=600)

# DO — explicit invalidation alongside the write that changes the source data
async def update_profile(user_id: str, data: ProfileUpdate):
    await db.update_profile(user_id, data)
    await redis.delete(f"v2:user:{user_id}:profile")
```

Prefer explicit invalidation at the write path when the write path is known and
reachable — it's more precise than a TTL alone. Fall back to TTL-only when the value
is cheap to recompute, staleness for that window is acceptable, or the set of writers
that could change it isn't fully enumerable (e.g. an externally-sourced value).

## Never cache side effects or unscoped sensitive data

**Hard rule**: never cache the result of an operation that has side effects (sends an
email, charges a payment, writes an audit log) — a cache hit on a subsequent call
means the side effect silently doesn't happen a second time, even when the caller
needed it to. Caching is for idempotent reads/computations only.

```python
# DON'T — a cache hit means the second caller's webhook never actually fires
async def notify_and_get_status(order_id: str) -> str:
    key = f"v1:order:{order_id}:status"
    cached = await redis.get(key)
    if cached:
        return cached
    await send_webhook(order_id)  # side effect — must not be skipped by a cache hit
    status = await compute_status(order_id)
    await redis.set(key, status, ex=60)
    return status

# DO — side effect runs unconditionally; only the pure computation is cached
async def notify_and_get_status(order_id: str) -> str:
    await send_webhook(order_id)
    key = f"v1:order:{order_id}:status"
    cached = await redis.get(key)
    if cached:
        return cached
    status = await compute_status(order_id)
    await redis.set(key, status, ex=60)
    return status
```

**Hard rule**: a cache key for user-scoped or auth-sensitive data must include the
scoping identifier (user ID, org ID, permission level) in the key itself. A key that
omits it and is shared across users is a security bug wearing a performance-feature
costume — the first user's request populates the cache, and every subsequent user
with a different scope gets served *that* user's data.

```python
# DON'T — shared key; whichever user's request populates the cache, every other
# user calling this endpoint gets served that user's own order data
key = "v1:my_orders"

# DO — scoped to the requesting user; no cross-user leakage possible
key = f"v1:user:{current_user.id}:my_orders"
```

This applies even when the underlying query itself is correctly scoped
(`WHERE user_id = ...`) — the bug is in the cache key, not the query, and a correct
query behind a shared cache key still serves the wrong user's cached result.

## Advisory: cache backend choice

Redis vs. Memcached vs. a plain in-memory dict (for a single-instance app with no
need for cross-process sharing) is a project/infrastructure decision, not something
this skill enforces. The skill enforces the *practice* — keys are versioned and
scoped correctly, invalidation is deliberate — which is portable across any backend.
Don't flag a project's backend choice as a violation; note it only if asked to audit
tooling specifically.

## Advisory: TTL duration

How long a given value should stay cached (30 seconds vs. 30 minutes) is a
data-freshness/business decision specific to the value and project, not something
this skill prescribes numbers for. The hard rule is that *some* invalidation plan
exists (see above) — the specific TTL chosen is advisory.

## Anti-patterns

### Hard rules — always flag as violations

| Anti-pattern | Why it's wrong | Fix |
|---|---|---|
| Cache key with no version/namespace segment, where invalidation relies on it | A schema/logic change silently serves stale-shaped data under the old key forever. | Versioned key (`v2:...`); bump the version when the computation/shape changes. |
| Caching added with no TTL and no explicit invalidation path | Stale data served silently is a correctness bug, worse than the slow path it replaced. | Add a TTL, an explicit invalidation on the write path, or both. |
| Caching the result of an operation with side effects (email, payment, audit log) | A cache hit silently skips the side effect on repeat calls. | Cache only pure/idempotent reads or computations; run side effects unconditionally. |
| Cache key for user-scoped/auth-sensitive data missing the scoping identifier | First user's request populates the cache; every other user gets served that user's data. | Include the user/org/permission-level identifier in the key itself. |

### Structural preferences — advisory, respect existing convention

| Pattern | Rationale | If the project uses a different convention |
|---|---|---|
| Redis vs. Memcached vs. in-memory dict as the cache backend | Infrastructure decision, not a correctness rule. | Don't flag; note only if asked to audit tooling specifically. |
| Specific TTL duration chosen for a given cached value | Data-freshness/business decision per value and project. | Don't flag; respect the project's chosen window as long as *some* invalidation plan exists. |
