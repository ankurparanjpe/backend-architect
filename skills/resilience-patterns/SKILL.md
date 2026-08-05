---
name: resilience-patterns
description: >
  Cross-cutting backend resilience rules that apply regardless of framework: explicit
  timeouts on every outbound call, retry safety (idempotency keys and backoff), circuit
  breaking / fail-fast on a repeatedly failing dependency, and isolating non-critical
  downstream calls from the critical request path. Use when the work reaches out to an
  external service — an outbound HTTP request, a database call, a third-party SDK
  invocation, a webhook, a payment or email provider — or touches timeout values, retry
  logic, backoff, circuit breakers, fallbacks, bulkheads, or graceful degradation when a
  dependency is slow, erroring, or down — in any backend framework (FastAPI, Django,
  Flask, Express, etc.) or with no framework named at all. This skill covers *behavior under failure*: what
  the service does when a dependency misbehaves. It does not cover client/connection
  reuse or pool sizing for throughput (see backend-performance), logging or tracing of
  failures once they occur (see backend-observability), the error-response shape and
  status code returned to your own caller (see backend-security), or framework-specific
  background-job wiring (see fastapi-architecture).
---

# Resilience Patterns

Cross-cutting resilience rules for backend APIs, independent of framework. Applies
alongside framework-specific skills (fastapi-architecture, django-architecture,
flask-architecture) rather than replacing them — this skill covers *what* the failure
behavior must be; the framework skill covers *how* to wire it in that framework.

Every rule here is about one question: when a dependency is slow, erroring, or down,
what does this service do? Detecting and recording that failure belongs to
backend-observability; deciding the behavior belongs here.

## Scope

**Protocol scope**: these rules are written against request/response HTTP APIs (REST-style).
Where a rule names an HTTP status code, header, or URL, that's the HTTP mechanism for a
principle that generalizes across protocols — GraphQL, gRPC, and WebSocket APIs differ in
mechanism and aren't covered here.

This skill enforces two different kinds of rules:

- **Hard rules** — resilience gaps where a single misbehaving dependency takes down
  capacity for unrelated requests: an outbound call (HTTP request, DB query, third-party
  SDK call) issued with no explicit timeout, a retry wrapped around a non-idempotent
  operation with no idempotency key, retries with no backoff between attempts, a
  dependency that keeps being called after it has proven it is failing, and a
  non-critical downstream call sitting on the critical path so its outage fails the
  primary request. These are flagged as violations regardless of the project's age or
  existing conventions.
- **Structural preferences** — advisory only: which circuit-breaker library or decorator
  is used, and the specific backoff algorithm and timing values (base delay, multiplier,
  jitter, max attempts, timeout seconds, failure threshold). These are tuning decisions
  that depend on the dependency's real latency profile and blast radius — this skill
  requires that a deliberate value exists and was reasoned about, and does not prescribe
  what the number should be. If a project has an established convention that differs,
  don't flag it as a violation — note it only if asked to audit tooling specifically.

## Timeouts on every external call

**Hard rule**: every call that leaves the process carries an explicit timeout — HTTP
client requests, database queries, cache calls, message-broker publishes, and
third-party SDK calls alike. A call with no timeout inherits whatever the library
defaults to, which for most HTTP clients and drivers is *no deadline at all*.

The failure mode is not a slow response, it's lost capacity. A worker blocked on a
socket that will never answer is a worker that serves no other request. Enough of them
and the pool is exhausted, and requests that never touch the broken dependency start
timing out too — one struggling upstream becomes a full outage.

```python
# DON'T — no deadline; if upstream accepts the connection and then never
# responds, this coroutine and its worker slot are held indefinitely
async def fetch_upstream(item_id: str):
    return await http_client.get(f"https://upstream/items/{item_id}")

# DO — an explicit deadline, so a hung upstream fails this one request
# instead of consuming capacity for every other request
async def fetch_upstream(item_id: str):
    return await http_client.get(
        f"https://upstream/items/{item_id}",
        timeout=httpx.Timeout(2.0, connect=1.0),
    )
```

Setting the timeout once on the shared client is better than repeating it per call, and
composes with the reuse rule in backend-performance § HTTP/DB client reuse — one client,
constructed at startup, carrying a default deadline:

```python
# DO — one reused client, and no call through it can be unbounded
http_client = httpx.AsyncClient(timeout=httpx.Timeout(5.0, connect=2.0))
```

Databases and SDKs need the same treatment and are more often missed, because a query
feels local in a way an HTTP call doesn't. It isn't — it's a socket to another machine.
Use the driver's statement/query timeout (`statement_timeout` on PostgreSQL,
`max_execution_time` on MySQL) and whatever the SDK exposes; if an SDK exposes no timeout
at all, that's a reason to wrap the call, not a reason to skip the rule.

**gRPC note**: gRPC's equivalent of an HTTP client timeout is a per-call deadline
(a context deadline propagated from client to server), not a status code — set one on
every call, the same as an HTTP timeout above.

A timeout that fires is a handled failure, not a crash — pair it with one of the
degradation strategies below so the caller gets a defined answer.

## Retries: idempotency first, then backoff

**Hard rule**: a retry is only safe when repeating the operation is safe. Retrying a
non-idempotent operation — a `POST` that creates a resource, a charge, a transfer, a
send — with no idempotency key is a duplication bug, not a resilience measure.

The trap is that the dangerous case looks identical to the safe one from inside the
client. A request that times out, or fails with a `5xx`, or dies mid-flight, may have
been fully processed upstream before the response was lost. Retry it and you have two
orders, two charges, two emails. The absence of a response is not evidence of the
absence of an effect.

```python
# DON'T — the timeout may fire *after* the charge succeeded upstream; each
# retry creates another charge, and the customer is billed three times
async def charge_customer(customer_id: str, amount_cents: int):
    for _ in range(3):
        try:
            return await http_client.post(
                "https://payments/charges",
                json={"customer": customer_id, "amount": amount_cents},
                timeout=5.0,
            )
        except httpx.TimeoutException:
            continue

# DO — a caller-generated key makes the operation idempotent: upstream
# recognizes the repeat and returns the original result instead of charging again
async def charge_customer(customer_id: str, amount_cents: int, idempotency_key: str):
    for attempt in range(3):
        try:
            return await http_client.post(
                "https://payments/charges",
                json={"customer": customer_id, "amount": amount_cents},
                headers={"Idempotency-Key": idempotency_key},
                timeout=5.0,
            )
        except httpx.TimeoutException:
            if attempt == 2:
                raise
            await asyncio.sleep(BASE_DELAY * 2**attempt + random.uniform(0, JITTER))
```

The key must be derived from the *intent* of the operation and generated by the caller,
stable across retries of the same logical request — a fresh `uuid4()` per attempt
defeats the entire mechanism. If the upstream supports no idempotency key, the operation
is not retryable at the call site: push the retry to a durable job that can record
what it already did (see § Async task retries), or surface the failure to a caller who
can decide.

Reads (`GET`), and writes that are naturally idempotent (`PUT` of a full state, a
`DELETE` of a specific id) — the HTTP/REST idempotency convention — are safe to retry
without a key.

**Hard rule**: retries have backoff. A tight-loop retry — no delay between attempts —
turns a dependency's bad moment into a self-inflicted denial of service: the upstream is
struggling, and every one of your workers responds by multiplying its request rate
exactly when it has least capacity to absorb it. Recovery becomes impossible while you
keep the pressure on.

```python
# DON'T — three attempts as fast as the loop can issue them, tripling load
# on a dependency that is already failing
for _ in range(3):
    try:
        return await fetch_upstream(item_id)
    except httpx.HTTPError:
        continue
```

Backoff must also be *bounded*: a finite attempt cap, and a total retry budget that
stays inside the deadline of the request that triggered it. Retries nested inside
retries at several layers multiply — three attempts at each of three layers is
twenty-seven calls — so decide which single layer owns the retry and let the others
propagate.

The specific algorithm and numbers are advisory (see § Advisory: backoff algorithm and
timing values); what's non-negotiable is that some delay exists and grows.

## Circuit breaking: stop calling a dependency that has proven it's failing

**Hard rule** (on behavior): once a dependency has failed repeatedly, stop calling it
for a cooling-off period and fail fast instead. A single flaky dependency must not
cascade into taking down the whole request path.

Timeouts bound one call, and backoff paces one call's retries. Neither helps when a
dependency is *durably* down: every incoming request still pays the full timeout before
failing, so latency pins at the timeout value and workers spend their time waiting on a
service everyone already knows is broken. Failing immediately is both faster for the
caller and the only thing that gives the dependency room to recover.

The behavior has three states, whatever implements it:

- **closed** — calls pass through; consecutive failures are counted.
- **open** — the failure threshold was crossed; calls are rejected immediately without
  touching the network, for a cooling-off window.
- **half-open** — after the window, a single trial call is allowed. Success closes the
  breaker; failure re-opens it for another window.

```python
# DON'T — upstream has been down for ten minutes; every request still burns
# the full 5s timeout before failing, and every worker is parked in this wait
async def get_recommendations(user_id: str):
    return await http_client.get(f"https://recs/users/{user_id}", timeout=5.0)

# DO — a breaker rejects immediately while upstream is known-down, so the
# request path stays fast and the dependency gets room to recover
@breaker  # opens after N consecutive failures, retries after a cooling-off window
async def get_recommendations(user_id: str):
    return await http_client.get(f"https://recs/users/{user_id}", timeout=5.0)
```

What's flagged is the missing behavior, not a missing library. A hand-rolled failure
counter that fails fast satisfies this rule; so does a platform-level breaker in a
service mesh or gateway, if that's where it lives. What doesn't satisfy it is a
repeatedly-failing dependency being called at full rate forever.

Breakers are per-dependency, never global — one shared breaker means a failure in the
recommendations service starts rejecting calls to the payments service. And an open
breaker still needs an answer for the caller: fail fast *to* something, per the next
section.

## Isolate non-critical dependencies from the critical path

**Hard rule**: a dependency that isn't required for the primary result must not be able
to fail the primary request. Classify each downstream call as critical or not, and let
the non-critical ones degrade.

Most request paths accumulate calls that have nothing to do with the answer being
returned: analytics events, audit pings, recommendation widgets, notification sends,
enrichment lookups. Left inline and unguarded, each one is a full-severity dependency —
the analytics vendor's outage becomes your checkout outage, and the incident is
mystifying because nothing in the critical path changed.

```python
# DON'T — an analytics vendor being slow or down fails a checkout that
# has already succeeded; the order is created and the customer sees a 500
@router.post("/orders")
async def create_order(data: OrderIn):
    order = await service.create_order(data)
    await analytics.track("order_created", order.id, timeout=2.0)  # not critical!
    return order

# DO — the non-critical call cannot fail the request; it degrades instead
@router.post("/orders")
async def create_order(data: OrderIn, bg: BackgroundTasks):
    order = await service.create_order(data)
    bg.add_task(analytics.track, "order_created", order.id)
    return order

# DO — when it must stay inline, contain the failure explicitly
    try:
        await analytics.track("order_created", order.id, timeout=1.0)
    except Exception:
        logger.warning("analytics_track_failed", extra={"order_id": order.id})
    return order
```

Degradation needs to be a defined outcome, not an accident. Pick one per dependency and
make it explicit: move the call off the request path (queue or background task), serve a
cached or stale value, omit the optional section from the response, substitute a
neutral default — or, for a genuinely critical dependency, fail the request cleanly with
the right status code (see backend-security § error responses for which code and what
shape). What's flagged is an unguarded non-critical call, and a bare `except: pass` that
swallows a failure with no record of it — containment is not silence, so log the
degraded path at `WARNING` per backend-observability § log levels.

The same isolation logic applies to shared resources, not just call sites: if all
outbound calls share one connection pool or worker pool, a slow non-critical dependency
can occupy every slot and starve the critical ones. Separate pools per dependency class
is the structural version of this rule; pool sizing itself belongs to
backend-performance § Connection pool sizing.

## Async task retries: design for safe resumption

Background and queued jobs get interrupted — a worker is redeployed, killed by an
autoscaler, or dies mid-task — and the job runner's answer is to run the task again.
That makes safe resumption a design requirement for the task body, not a property of the
queue: a task that is partway through a batch when it dies must be safe to re-run from
the top, or must record its progress so the re-run skips what already happened.

The concrete rules are the retry rules above, applied to the task body: make each step
idempotent (upsert rather than insert, check-then-act guarded by a unique constraint,
record a processed-marker per item), back off between attempts, and cap them so a
permanently-failing task lands in a dead-letter queue instead of retrying forever.

The mechanism — which runner, how retries and dead-lettering are configured, and why
in-process background tasks are not durable at all — is owned by the framework skill.
See fastapi-architecture § Background work for the `BackgroundTasks` vs. Celery/Arq/RQ
decision and the durability warning; django-architecture/flask-architecture add their
equivalent pointers here once those skills cover it. Don't restate that mechanism in
this skill.

## Advisory: circuit-breaker library and implementation

Which breaker implementation a project uses — `pybreaker`, `purgatory`, a
`tenacity`-based wrapper, a hand-rolled counter, or a breaker in the service mesh or API
gateway — is an infrastructure and dependency decision, not a correctness rule. The hard
rule is that the fail-fast behavior exists per dependency (see above); the mechanism is
advisory. If a project already has a convention, use it rather than introducing a second
one.

## Advisory: backoff algorithm and timing values

The backoff algorithm (fixed, linear, exponential, decorrelated jitter), the numbers
attached to it (base delay, multiplier, max attempts, total retry budget), the timeout
seconds per dependency, and the breaker's failure threshold and cooling-off window are
all tuning decisions. They depend on the dependency's real latency distribution, its
recovery behavior, and how much a failed request costs — no universal values exist, and
this skill prescribes none.

Two things are not advisory: some delay must exist and must grow (§ Retries), and each
value must be a deliberate choice rather than a library default nobody looked at.
Exponential backoff with jitter is the reasonable default to reach for when there's no
established convention — jitter specifically, because synchronized retries across many
workers arrive as a thundering herd even when each one backs off politely.

## Anti-patterns

### Hard rules — always flag as violations

| Anti-pattern | Why it's wrong | Fix |
|---|---|---|
| Outbound call (HTTP request, DB query, cache/broker call, third-party SDK call) with no explicit timeout | Most clients default to no deadline; one hung upstream holds workers indefinitely and exhausts capacity for requests that don't touch it. | Set an explicit timeout — on the shared client as a default, and per call where it differs. Use the driver's statement/query timeout for DB calls. |
| Retry around a non-idempotent operation (`POST` that creates, charge, transfer, send) with no idempotency key | A lost response is not proof the operation didn't happen — retries duplicate the effect (double charge, double order). | Send a caller-generated `Idempotency-Key` stable across retries of the same logical request; if upstream supports none, move the retry to a durable job or surface the failure. |
| Idempotency key regenerated per attempt (`uuid4()` inside the retry loop) | Each attempt looks like a new operation to upstream, so the key protects nothing. | Generate the key once from the intent of the operation, outside the retry loop. |
| Retries with no backoff (tight loop, fixed zero delay) | Multiplies load on a dependency exactly when it has least capacity, preventing the recovery the retry was waiting for. | Delay between attempts, growing per attempt, with a finite cap and a total budget inside the caller's deadline. |
| Unbounded retries, or nested retry layers that multiply | No attempt cap means a permanently-broken dependency is called forever; 3 attempts × 3 layers is 27 calls per request. | Cap attempts; pick the single layer that owns the retry and let the others propagate. |
| Dependency called at full rate after repeated failures — no fail-fast path | Every request pays the full timeout on a known-down service, pinning latency at the timeout and parking workers in a wait everyone knows will fail. | Fail fast after a failure threshold, with a cooling-off window and a trial call before resuming (breaker library, hand-rolled counter, or mesh-level — any is fine). |
| One global/shared circuit breaker across unrelated dependencies | A failure in one dependency starts rejecting calls to healthy, unrelated ones. | One breaker per dependency. |
| Non-critical downstream call (analytics, audit ping, recommendations, notification) inline and unguarded on the critical path | A vendor with no bearing on the response can fail a request whose primary work already succeeded. | Move it off the request path (queue/background task), or contain it inline with an explicit fallback; never let it propagate. |
| Failure swallowed with a bare `except: pass` and no record | Containment becomes invisibility — the degraded path is indistinguishable from the healthy one in production. | Contain the failure *and* log it at `WARNING` with context (see backend-observability). |
| Queued/background task body that isn't safe to re-run after interruption | Workers get killed mid-task and the runner re-runs it; a non-resumable body double-applies its effects or resumes corrupt. | Make each step idempotent (upsert, unique-constraint guard, per-item processed marker); cap attempts with a dead-letter destination. |

### Structural preferences — advisory, respect existing convention

| Pattern | Rationale | If the project uses a different convention |
|---|---|---|
| Circuit-breaker implementation (`pybreaker`, `tenacity` wrapper, hand-rolled counter, mesh/gateway-level) | Infrastructure and dependency choice, not a correctness rule. | Don't flag; the fail-fast behavior is what matters. Note only if asked to audit tooling specifically. |
| Backoff algorithm chosen (fixed, linear, exponential, decorrelated jitter) | Depends on the dependency's recovery behavior and caller count. | Don't flag, as long as the delay exists and grows. |
| Specific timing values (base delay, multiplier, max attempts, timeout seconds, breaker threshold and cooling-off window) | Depends on the dependency's real latency profile and the cost of a failed request — no universal numbers. | Don't flag; respect them as long as they're reasoned choices rather than untouched library defaults. |
| Which degradation strategy a non-critical dependency uses (queue it, stale cache, omit the field, neutral default) | Product decision about what a partial answer should look like. | Don't flag; the rule is that *some* defined degradation exists, not which one. |
