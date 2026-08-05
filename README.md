# backend-architect

[![CI](https://github.com/ankurparanjpe/backend-architect/actions/workflows/ci.yml/badge.svg)](https://github.com/ankurparanjpe/backend-architect/actions/workflows/ci.yml)

A Claude Code plugin that enforces production-grade backend architecture standards while you
write and review code. It ships two framework skills (FastAPI, Django) plus five
cross-cutting skills (security, observability, caching, performance, testing) that apply to
any backend, and an `/audit-architecture` command that runs the applicable ones over a file,
path, or diff. A Flask framework skill is a planned sibling, not yet implemented.

## Scope: hard rules vs structural preferences

This is the plugin's core design decision, and worth understanding before you install it.
Every skill splits its content into two kinds of rules:

- **Hard rules** — correctness and reliability issues: blocking calls in `async def`,
  wildcard CORS with credentials, secrets in code, unpaginated list endpoints, cache keys
  that don't include the user scope. These are bugs, not style choices. They're flagged as
  violations regardless of the project's age or its existing conventions.
- **Structural preferences** — organizational recommendations: domain-based vs layered
  folder structure, file layout, naming. These are **advisory only**. If your project
  already has an established convention that differs, the skill won't flag it as a
  violation — at most it notes "this project uses X instead of the domain-based
  convention," and only when you explicitly ask for a structure audit.

The split exists specifically so the plugin doesn't fight an established codebase. A
recommendation that's right for a fresh project is not a migration target for a working one,
and a review tool that can't tell the difference gets uninstalled. Hard rules are the part
worth arguing about; structure is the part worth leaving alone.

See [`skills/fastapi-architecture/SKILL.md`](skills/fastapi-architecture/SKILL.md) §Scope
for the reference wording every skill follows.

The five cross-cutting skills are also scoped to one protocol: they're written against
request/response HTTP APIs (REST-style). Where a rule names an HTTP status code, header,
or URL, that's the HTTP mechanism for a principle that generally carries over to other
protocols — GraphQL, gRPC, and WebSocket APIs differ in mechanism and aren't covered yet.

## Installation

```
/plugin marketplace add ankurparanjpe/backend-architect
/plugin install backend-architect@backend-architect
```

The `@backend-architect` suffix is the marketplace name (the repo hosts a single-plugin
marketplace, so plugin and marketplace share the name).

## What's included

| Skill | Covers |
|---|---|
| `fastapi-architecture` | FastAPI-specific rules: async vs sync routes, `BackgroundTasks` vs Celery/Arq/RQ, `Annotated` dependency injection, SQLAlchemy 2.0 async conventions, domain-based project structure, ruff defaults (including the `ASYNC` ruleset that catches blocking calls at lint time), Uvicorn/Gunicorn workers, lifespan/health checks, and keeping dev tooling out of the deployed dependency set. |
| `django-architecture` | Django-specific rules: one app per bounded domain, the sync-ORM-inside-`async def`-view hazard (sync stays the default), DRF serializers as the input-validation boundary, `select_related`/`prefetch_related` eager loading, serializer `fields` projection, `settings.py` hardening (`DEBUG`, `SECRET_KEY`, `ALLOWED_HOSTS`, CSRF middleware, `check --deploy`), and migration discipline (never edit an applied migration, `makemigrations --check` in CI, `apps.get_model` in data migrations). |
| `backend-security` | CORS configuration, rate limiting, secrets and env handling, security headers, boundary input validation, error-response standardization (consistent schema, correct status codes, no leaked internals), auth patterns beyond JWT decode. |
| `backend-observability` | Structured logging, request/correlation ID propagation, service-boundary logging, secret/PII redaction, log level discipline, exception logging with context. |
| `backend-caching` | Cache layering (HTTP/application/dependency), key design and versioning, invalidation strategy, safe scoping of cached data. |
| `backend-performance` | Pagination enforcement, HTTP/DB client reuse, connection pool sizing, N+1 query detection, response payload shaping, backing performance claims with a repeatable benchmark. |
| `resilience-patterns` | Behavior under failure: explicit timeouts on every outbound call, safe retries (idempotency keys, backoff), circuit breaking / fail-fast on a failing dependency, isolating non-critical downstream calls from the critical path, resumable background jobs. |
| `testing-standards` | Test pyramid balance (unit for logic, integration at I/O boundaries), test isolation and order independence, fixtures vs mocks, which paths must have tests, contract tests guarding consumer-facing response shapes. |

Planned, not yet implemented: `flask-architecture`. Until it exists, `/audit-architecture`
detects Flask, says the framework skill is missing, and runs the cross-cutting skills only.

## Usage

**Natural language.** The skills carry trigger conditions in their descriptions, so ordinary
review requests pull in the right ones automatically:

```
Review this router for anything that'll break in production.
Is my Redis caching layer safe for per-user data?
Why is this list endpoint slow?
```

**`/audit-architecture`** for a deliberate, grouped pass. Each skill runs in its own
subagent so one skill's rules don't bleed into another's review, and results come back
grouped by skill, hard-rule violations separated from advisory notes.

```
/audit-architecture                              # the current diff (staged, else unstaged)
/audit-architecture src/orders/router.py          # one file
/audit-architecture src/orders/                   # a directory
/audit-architecture src/ --framework=fastapi      # skip framework auto-detection
/audit-architecture --skip=backend-caching,backend-performance
```

- `--framework=fastapi|django|flask` — override auto-detection.
- `--skip=<comma-separated skill names>` — exclude skills; they're reported as "skipped by
  request" rather than silently dropped.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) — adding a hard rule to an existing skill, proposing a
new skill, and the conventions any new skill content has to keep.

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs two checks on every push and
pull request: manifest validation plus the version-bump rule (`tests/check_version_bump.sh`,
hard fail), and a warning-only scan for overlapping trigger wording across skill descriptions
(`python3 tests/check_descriptions.py`). Both run locally as well.

CI does **not** run the skill fixture checks in `tests/fixtures/` — those invoke `claude -p`,
so they need API access, and verifying them is a contributor responsibility. A green badge
means the manifests and version bump are fine, not that every skill's rules still fire. See
[CONTRIBUTING.md](CONTRIBUTING.md#what-ci-checks).

## Attribution

`fastapi-architecture`'s async/blocking-call reasoning, dependency-injection conventions, and
domain-based project structure draw on
[zhanymkanov/fastapi-best-practices](https://github.com/zhanymkanov/fastapi-best-practices).
Worth reading directly — it's the source material, and covers ground this plugin doesn't
encode as rules.

## License

MIT — see [LICENSE](LICENSE).
