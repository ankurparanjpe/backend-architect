---
name: backend-performance
description: >
  Cross-cutting backend performance rules that apply regardless of framework: pagination
  enforcement on list endpoints, HTTP/DB client reuse, connection pool sizing, N+1 query
  detection, and response payload shaping. Use when the work touches list/collection
  endpoints with no pagination, a client or session constructed inside a request handler
  instead of reused, DB pool configuration, a loop issuing one query per row, or serializing
  a full ORM object/graph into a response — in any backend framework (FastAPI, Django,
  Flask, Express, etc.) or with no framework named at all. This skill states the
  cross-cutting principle and hard rule; framework-specific mechanism and syntax
  (SQLAlchemy pool arguments, selectinload/joinedload, response_model field projection)
  live in the sibling framework skill (fastapi-architecture, django-architecture,
  flask-architecture) and are cross-referenced from here so the two don't drift out of
  sync. Does not cover caching (see backend-caching), logging/tracing (see
  backend-observability), or authentication/rate limiting (see backend-security).
---

# Backend Performance

Cross-cutting performance rules for backend APIs, independent of framework. Applies
alongside framework-specific skills (fastapi-architecture, django-architecture,
flask-architecture) rather than replacing them — this skill covers *what* the practice
must be; the framework skill covers *how* to wire it in that framework.

## Scope

This skill enforces two different kinds of rules:

- **Hard rules** — performance mistakes that cause outages or unbounded resource growth
  rather than just suboptimal tuning: list endpoints with no pagination enforcement, a new
  HTTP/DB client or session constructed inside a request handler instead of a reused
  pooled one, a connection pool size left unexamined at the driver default instead of
  reasoned about against worker count and the database's max-connections limit, N+1 query
  patterns that turn one request into per-row round trips, and serializing an entire ORM
  object/graph into a response instead of the fields the response contract actually needs.
  These are flagged as violations regardless of the project's age or existing conventions.
- **Structural preferences** — advisory only: the specific default/max page size chosen
  for pagination, and the specific pool-size number chosen once it's been reasoned about.
  These are project/traffic-shape decisions this skill does not prescribe numbers for — if
  a project has an established convention, don't flag it as a violation; note it only if
  asked to audit tooling specifically.

## Pagination enforcement

**Hard rule**: every list/collection endpoint enforces a bound on the number of rows it
can return — either `limit`/`offset` params with a capped max, or cursor-based pagination.
An endpoint with no bound at all means response size and query cost grow linearly with the
table, unbounded, until one request is slow enough to be an outage.

```python
# DON'T — no bound at all; this query returns every row in the table, today
# and forever, as the table grows
@router.get("/orders")
async def list_orders():
    result = await db.execute(select(Order))
    return result.scalars().all()

# DO — bounded, with a capped max so a caller can't opt into unbounded either
@router.get("/orders")
async def list_orders(
    limit: int = Query(20, ge=1, le=100),
    offset: int = Query(0, ge=0),
):
    result = await db.execute(select(Order).limit(limit).offset(offset))
    return result.scalars().all()
```

This applies equally to a raw SQL `SELECT *` with no `LIMIT`, a Django `Model.objects.all()`
returned directly from a view with no `Paginator`, or any other framework's equivalent —
the rule is about the absence of a bound, not the specific pagination API used to enforce
it.

## HTTP/DB client reuse

**Hard rule**: never construct a new HTTP client, DB client, or session inside a request
handler — construct it once (at process/app startup) and reuse the same pooled instance
across requests. A client constructed per request pays connection-setup cost on every
single call and opens its own pool instead of sharing one; under load this serializes or
exhausts the upstream faster than the actual work would.

```python
# DON'T — a new client, and a new underlying connection pool, is opened and
# torn down on every single request
async def fetch_upstream(item_id: str):
    async with httpx.AsyncClient() as client:
        return await client.get(f"https://upstream/items/{item_id}")

# DO — one client, constructed once, reused across requests
http_client = httpx.AsyncClient(timeout=httpx.Timeout(5.0, connect=2.0))

async def fetch_upstream(item_id: str):
    return await http_client.get(f"https://upstream/items/{item_id}")
```

fastapi-architecture's Lifespan section already demonstrates the FastAPI-specific
mechanism for this — constructing the client once in `lifespan` and storing it on
`app.state`. That skill covers the *how*; this rule covers the *what/why* and applies even
when no framework is named. See fastapi-architecture § Production deployment → Lifespan
handlers. When django-architecture/flask-architecture exist, they add their own pointer
here for their equivalent mechanism.

The `timeout=` on the reused client above is a resilience rule, not a performance one —
this skill requires the client be reused; resilience-patterns § Timeouts on every
external call requires that no call through it be unbounded. Both apply to the same
call site.

## Connection pool sizing

**Hard rule**: a database connection pool's size is a deliberate choice, reasoned about
against worker count and the database's own max-connections limit — not left untouched at
the driver default. A pool sized too small serializes requests behind pool-checkout waits;
one sized too large (especially multiplied across several worker processes) can exhaust
the database's connection limit for every other client sharing it.

The specific number is framework/driver-specific — see fastapi-architecture § Database for
SQLAlchemy's `pool_size`/`max_overflow`/`pool_timeout` arguments and how to reason about
them against Gunicorn worker count.

## N+1 query prevention

**Hard rule**: detect and eliminate N+1 query patterns — a loop that issues one query per
row of an earlier result, turning what should be one request into 1+N round trips. This
scales linearly with result size instead of staying constant, and is invisible in
development with a handful of rows but becomes the dominant cost in production.

```python
# DON'T — one query to fetch orders, then one more query per order to fetch
# that order's items: 1 request becomes 1 + N round trips
orders = (await db.execute(select(Order))).scalars().all()
for order in orders:
    items = await db.execute(select(Item).where(Item.order_id == order.id))
    order.items = items.scalars().all()
```

The fix — eager-loading the related data in the original query — is entirely
ORM-specific, so it's owned by the framework skill: see fastapi-architecture § Database
for SQLAlchemy's `selectinload`/`joinedload` and when to use each. Django's
`select_related`/`prefetch_related` is the equivalent for django-architecture once that
skill exists.

## Response/payload shaping

**Hard rule**: a response serializes only the fields its contract defines, never a full
ORM object or object graph. Returning the raw ORM row leaks whatever the model happens to
contain (internal flags, other relationships, sometimes secrets) and spends CPU/bandwidth
serializing data the client never asked for and the response contract never promised.

```python
# DON'T — the entire ORM row (every column, every loaded relationship) gets
# serialized, including fields the response contract never promised
@router.get("/users/{user_id}")
async def get_user(user_id: str):
    return await db.get(User, user_id)  # includes password_hash, internal flags, etc.

# DO — response_model projects only the fields the contract needs
@router.get("/users/{user_id}", response_model=UserPublic)
async def get_user(user_id: str):
    return await db.get(User, user_id)
```

See fastapi-architecture § Anti-patterns for `response_model` discipline in FastAPI
specifically (including the double-construction pitfall of also returning an already-typed
Pydantic model). Django REST Framework's serializer `fields=`/`exclude=` is the equivalent
for django-architecture once that skill exists.

## Anti-patterns

### Hard rules — always flag as violations

| Anti-pattern | Why it's wrong | Fix |
|---|---|---|
| List endpoint with no pagination/bound enforcement | Response size and query cost grow unbounded as the table grows — a correctness gap becomes an outage under scale. | Require `limit`/`offset` or cursor params; cap the max page size; reject requests with no bound. |
| New HTTP/DB client or session constructed inside a request handler | Each request pays connection-setup cost and opens its own pool instead of sharing one — throughput collapses under load. | Construct the client once at startup (e.g. FastAPI `lifespan`), reuse the same instance across requests. |
| Connection pool size left at the driver default with no reasoning against worker count / DB max connections | Too small serializes requests behind pool waits; too large (× worker count) exhausts the database's connection limit. | Size the pool deliberately: `workers × pool_size` should stay under the DB's max connections with headroom. |
| N+1 query pattern (one query per row of an earlier result) | Turns one request into 1+N round trips; cost scales linearly with result size instead of staying constant. | Eager-load the related data in the original query (see the framework skill for ORM-specific syntax). |
| Serializing a full ORM object/graph into a response | Leaks fields never meant to be public, and wastes CPU/bandwidth on data the client never asked for. | Project only the fields the response contract defines. |

### Structural preferences — advisory, respect existing convention

| Pattern | Rationale | If the project uses a different convention |
|---|---|---|
| Specific default/max page size chosen for pagination | Traffic-shape/business decision per endpoint, not a correctness rule. | Don't flag; respect the chosen values as long as *some* bound exists. |
| Specific pool-size number chosen | Depends on worker count, database tier, and traffic profile — no universal number. | Don't flag; respect it as long as it's a reasoned choice, not an untouched default. |
