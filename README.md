# backend-architect

[![CI](https://github.com/ankurparanjpe/backend-architect/actions/workflows/ci.yml/badge.svg)](https://github.com/ankurparanjpe/backend-architect/actions/workflows/ci.yml)

A Claude Code plugin that enforces production-grade backend architecture standards while you
write and review code. It ships nine skills — three framework skills (FastAPI, Django,
Flask) plus six cross-cutting skills that apply to any backend — and an
`/audit-architecture` command that runs the applicable ones over a file, path, or diff.

Install it once and the skills load themselves when a request matches; `/audit-architecture`
is there for when you want a deliberate, grouped pass instead. Nothing runs on a schedule and
there is no hook to configure — see [Usage](#usage).

## Scope: hard rules vs structural preferences

This is the plugin's core design decision, and worth understanding before you install it.
Every skill splits its content into two kinds of rules:

- **Hard rules** — correctness and reliability issues: blocking calls in `async def`,
  wildcard CORS with credentials, secrets in code, unpaginated list endpoints, cache keys
  that don't include the user scope. These are bugs, not style choices. They're flagged as
  violations regardless of the project's age or its existing conventions.
- **Structural preferences** — organizational recommendations: domain-based vs layered
  folder structure, Flask's `create_app()` factory, file layout, naming. These are
  **advisory only**. If your project already has an established convention that differs,
  the skill won't flag it as a violation — at most it notes "this project uses X instead of
  the domain-based convention," and only when you explicitly ask for a structure audit.

The split exists specifically so the plugin doesn't fight an established codebase. A
recommendation that's right for a fresh project is not a migration target for a working one,
and a review tool that can't tell the difference gets uninstalled. Hard rules are the part
worth arguing about; structure is the part worth leaving alone.

See [`skills/fastapi-architecture/SKILL.md`](skills/fastapi-architecture/SKILL.md) §Scope
for the reference wording every skill follows.

The six cross-cutting skills are also scoped to one protocol: they're written against
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

### Framework skills — at most one applies to a given project

| Skill | Covers |
|---|---|
| [`fastapi-architecture`](skills/fastapi-architecture/SKILL.md) | Async vs sync routes, `BackgroundTasks` vs Celery/Arq/RQ, `Annotated` dependency injection, SQLAlchemy 2.0 async conventions, domain-based project structure, ruff defaults (including the `ASYNC` ruleset that catches blocking calls at lint time), Uvicorn/Gunicorn workers, lifespan/health checks, and keeping dev tooling out of the deployed dependency set. |
| [`django-architecture`](skills/django-architecture/SKILL.md) | One app per bounded domain, the sync-ORM-inside-`async def`-view hazard (sync stays the default), DRF serializers as the input-validation boundary, `select_related`/`prefetch_related` eager loading, serializer `fields` projection, `settings.py` hardening (`DEBUG`, `SECRET_KEY`, `ALLOWED_HOSTS`, CSRF middleware, `check --deploy`), and migration discipline (never edit an applied migration, `makemigrations --check` in CI, `apps.get_model` in data migrations). |
| [`flask-architecture`](skills/flask-architecture/SKILL.md) | The `create_app()` application factory (advisory — recommended, not mandatory) vs a module-level `Flask()` instance, Blueprints for domain separation, the extensions-vs-factory circular-import footgun (`.init_app()` two-step), Marshmallow/Pydantic input validation in place of Flask's lack of built-in serializers, class-based config vs hardcoded values, async-view support since 2.0 as an escape hatch rather than a default posture, and Flask-SQLAlchemy's lazy-loading N+1 hazard. |

### Cross-cutting skills — apply to any backend, framework or not

| Skill | Covers |
|---|---|
| [`backend-security`](skills/backend-security/SKILL.md) | CORS configuration, rate limiting, secrets and env handling, security headers, boundary input validation, error-response standardization (consistent schema, correct status codes, no leaked internals), auth patterns beyond JWT decode. |
| [`backend-observability`](skills/backend-observability/SKILL.md) | Structured logging, request/correlation ID propagation, service-boundary logging, secret/PII redaction, log level discipline, exception logging with context. |
| [`backend-caching`](skills/backend-caching/SKILL.md) | Cache layering (HTTP/application/dependency), key design and versioning, invalidation strategy, safe scoping of cached data. |
| [`backend-performance`](skills/backend-performance/SKILL.md) | Pagination enforcement, HTTP/DB client reuse, connection pool sizing, N+1 query detection, response payload shaping, backing performance claims with a repeatable benchmark. |
| [`resilience-patterns`](skills/resilience-patterns/SKILL.md) | Behavior under failure: explicit timeouts on every outbound call, safe retries (idempotency keys, backoff), circuit breaking / fail-fast on a failing dependency, isolating non-critical downstream calls from the critical path, resumable background jobs. |
| [`testing-standards`](skills/testing-standards/SKILL.md) | Test pyramid balance (unit for logic, integration at I/O boundaries), test isolation and order independence, fixtures vs mocks, which paths must have tests, contract tests guarding consumer-facing response shapes. |

### What's not covered

WebSocket, GraphQL, and gRPC architecture; containerization and Kubernetes; messaging and
event-driven patterns; transactional consistency; multi-tenancy; API versioning; and
supply-chain security are all **out of scope today, deliberately rather than by oversight**.
[`ROADMAP.md`](ROADMAP.md) lists each gap, what a skill covering it would have to include,
and why it isn't here yet. Where a current rule's mechanism genuinely differs off HTTP/REST,
the skill says so in place rather than guessing — `backend-security` § Status codes carry the
failure carries both a GraphQL and a gRPC note.

## Usage

Install once. From there the plugin has two entry points, and neither one runs unless you
ask for it.

**Natural language — always available, nothing to invoke.** The skills carry trigger
conditions in their descriptions, so ordinary review requests pull in the right ones
automatically:

```
Review this router for anything that'll break in production.
Is my Redis caching layer safe for per-user data?
Why is this list endpoint slow?
```

**`/audit-architecture` — an explicit, grouped pass when you want one.** Each skill runs in
its own subagent so one skill's rules don't bleed into another's review, and results come
back grouped by skill, hard-rule violations separated from advisory notes.

```
/audit-architecture                               # the current diff (staged, else unstaged)
/audit-architecture src/orders/router.py          # one file
/audit-architecture src/orders/                   # a directory
/audit-architecture src/ --framework=fastapi      # skip framework auto-detection
/audit-architecture --skip=backend-caching,backend-performance
```

- `--framework=fastapi|django|flask` — override auto-detection. Useful in a monorepo, or for
  a shared library with no framework signal of its own.
- `--skip=<comma-separated skill names>` — exclude skills; they're reported as "skipped by
  request" rather than silently dropped.

There is no commit hook, no watcher, and no always-on mode. See [`FAQ.md`](FAQ.md) for why,
and for what to do when an audit of an older codebase turns up a long list.

## Documentation

- [`CONTRIBUTING.md`](CONTRIBUTING.md) — adding a hard rule, proposing a new skill, what CI
  checks and what it deliberately doesn't.
- [`ROADMAP.md`](ROADMAP.md) — known gaps and future skill areas.
- [`FAQ.md`](FAQ.md) — opt-in behavior, monorepos, using your own team's rules alongside
  these, and what to expect on a codebase that doesn't follow them yet.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) — adding a hard rule to an existing skill, proposing
a new skill, and the conventions any new skill content has to keep. If the gap you care about
is one of the areas in [`ROADMAP.md`](ROADMAP.md), start with an issue.

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs three checks on every push
and pull request: structural assertions over every skill and fixture
(`tests/check_skill_structure.sh`, hard fail), manifest validation plus the version-bump rule
(`tests/check_version_bump.sh`, hard fail), and a warning-only scan for overlapping trigger
wording across skill descriptions (`python3 tests/check_descriptions.py`). All three run
locally as well.

CI does **not** run the skill fixture checks in `tests/fixtures/` — those invoke `claude -p`,
so they need API access, and verifying them is a contributor responsibility. A green badge
means the structure, the manifests, and the version bump are fine, not that every skill's
rules still fire. See
[`CONTRIBUTING.md` § What CI checks](CONTRIBUTING.md#what-ci-checks).

## License

MIT — see [`LICENSE`](LICENSE).
