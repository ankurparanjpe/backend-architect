---
name: roadmap
description: Known gaps and future skill areas for backend-architect
---

# Roadmap

## Current coverage (stable, production-ready)

- ✅ FastAPI, Django, Flask architecture patterns
- ✅ Security (auth, CORS, rate limiting, secrets, headers, input validation)
- ✅ Observability (structured logging, correlation IDs, boundaries, secret redaction)
- ✅ Caching (layering, Redis, key versioning, invalidation, scope)
- ✅ Performance (pagination, N+1, connection pooling, benchmarking)
- ✅ Testing standards (pyramid, isolation, fixtures vs mocks, contract testing)
- ✅ Resilience patterns (timeouts, retries, circuit breakers, graceful degradation)
- ✅ Protocol scope clarity (HTTP/REST assumptions labeled; GraphQL/gRPC notes where safe)

## Intentional gaps (out of scope, noted but not covered)

### Protocol-specific skills (future)

- **WebSocket architecture** — connection ownership, auth, rooms, backpressure,
  reconnection, fan-out, graceful shutdown
- **GraphQL architecture** — schema boundaries, resolver authorization, persisted
  queries, complexity/depth limits, mutations, subscriptions, DataLoader lifecycle
- **gRPC architecture** — proto evolution, backward compatibility, interceptors,
  streaming flow control, service boundaries

### Infrastructure & operations (future)

- **Containerization** — Dockerfile hardening, non-root execution, multi-stage builds,
  dependency optimization, graceful termination
- **Kubernetes/orchestration** — probes, resource limits, scaling, autoscaling, pod
  affinity, secrets management
- **Operational SLOs** — metrics/tracing, sampling, alert design, error budgets,
  runbook ownership

### Data & consistency (future)

- **Transactional consistency** — transaction boundaries, isolation levels, locking,
  optimistic concurrency, outbox/inbox patterns
- **Messaging/event-driven** — consumer idempotency, ordering guarantees, poison
  messages, DLQs, schema evolution, replay
- **Multi-tenancy** — tenant isolation, authorization scoping, per-tenant quotas,
  data-access enforcement

### API & lifecycle (future)

- **API versioning** — breaking-change discipline, deprecation, pagination-token
  stability, OpenAPI compatibility
- **Supply-chain security** — lockfile discipline, vulnerability scanning, SBOMs,
  image scanning, secret scanning

## Why these are out of scope now

The current skills focus on *backend code architecture* — the patterns developers
write into Python. WebSocket/GraphQL/gRPC, containers, messaging, and multi-tenancy
require deep domain expertise per protocol/pattern and would dilute the plugin's focus
if added prematurely.

Where a current skill's rule touches one of these areas, it says so in place rather than
guessing: `backend-security` § Status codes carry the failure carries explicit GraphQL and
gRPC notes, `resilience-patterns` § Timeouts notes the gRPC deadline equivalent, and every
cross-cutting skill's `## Scope` states the HTTP/REST protocol assumption up front. A
labeled boundary is coverage of a kind; an unlabeled one is a wrong answer waiting to
happen.

## Contributing a new skill

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full process. In short: pick a gap, propose
it in an issue, and build following the hard rule / advisory split pattern already
established.
