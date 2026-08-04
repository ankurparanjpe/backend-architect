---
name: fastapi-architecture
description: >
  FastAPI-specific production architecture rules: async vs sync route decisions,
  BackgroundTasks vs Celery/Arq/RQ, Annotated-style dependency injection, SQLAlchemy 2.0
  async conventions, domain-based project structure, ruff linting defaults, Uvicorn/Gunicorn
  worker and lifespan/health-check patterns, and an anti-patterns checklist for reviewing
  FastAPI code. Use when the project imports `from fastapi import FastAPI`, instantiates
  `FastAPI()`, uses `APIRouter`/`Depends`, or otherwise clearly identifies as a FastAPI app
  (e.g. `main.py` with a FastAPI app, `uvicorn main:app`). Do not use for generic backend
  security, observability, caching, or performance questions with no FastAPI signal — those
  are covered by the sibling backend-security / backend-observability / backend-caching /
  backend-performance skills in this plugin.
---

# FastAPI Architecture

Production-grade rules for FastAPI services. Assumes FastAPI ≥ 0.115, Pydantic ≥ 2.7,
SQLAlchemy ≥ 2.0 (async), Python ≥ 3.11.

## Scope

This skill enforces two different kinds of rules:

- **Hard rules** — correctness and reliability issues: async/blocking-call misuse,
  `BackgroundTasks` used for work that needs retries or durability, missing input
  validation, secrets committed to code, and anything else that's a bug rather than a
  style choice. These are flagged as violations regardless of the project's age or
  existing conventions.
- **Structural preferences** — organizational recommendations: domain-based vs layered
  folder structure, naming conventions, file layout. These are advisory only. If a
  project already has an established structural convention (e.g. Clean Architecture /
  layered folders) that differs from the domain-based recommendation below, don't flag
  it as a violation — note it only if asked to audit structure specifically, and frame
  it as "this project uses X instead of the domain-based convention," not as an error.
  The domain-based structure is a recommendation for projects starting fresh with no
  existing convention, not a migration target for established codebases.

## Project structure (structural preference — advisory)

> Advisory, not a hard rule — see [Scope](#scope). This is the recommended layout for a
> **new** FastAPI project with no established convention. If an existing project already
> follows a different convention, don't flag deviations from this section as violations;
> only note them if asked to audit structure specifically.

One package per bounded context, when starting fresh. Don't split into global `routers/`,
`models/`, `schemas/` folders — that scatters everything about one feature across the
codebase.

```
src/
├── {domain}/           # e.g., auth/, posts/, aws/
│   ├── router.py       # API endpoints
│   ├── schemas.py      # Pydantic models
│   ├── models.py       # SQLAlchemy ORM models
│   ├── service.py      # Business logic
│   ├── dependencies.py # Route dependencies
│   ├── config.py       # Domain-scoped BaseSettings
│   ├── constants.py    # Constants and error codes
│   ├── exceptions.py   # Domain-specific exceptions
│   └── utils.py        # Helper functions
├── config.py           # Global BaseSettings
├── models.py           # Shared Pydantic / ORM bases
├── exceptions.py       # Global exceptions
├── database.py         # Async engine + session factory
└── main.py             # FastAPI app + lifespan
```

**Cross-domain imports**: always import the module, never `from src.auth import *` or reach
through deep paths.

```python
# DO
from src.auth import constants as auth_constants
from src.notifications import service as notification_service

# DON'T — tight coupling, hard to refactor
from src.auth.service.user import get_user
```

**Config**: one `BaseSettings` subclass per domain, not one giant settings object the whole
app reads from.

```python
# src/auth/config.py
from pydantic_settings import BaseSettings, SettingsConfigDict

class AuthConfig(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="AUTH_", env_file=".env", extra="ignore")
    JWT_ALG: str
    JWT_SECRET: str
    JWT_EXP_MINUTES: int = 5

auth_settings = AuthConfig()
```

## Async vs sync routes

### Decision rule

| Route does this                       | Use                                          |
|----------------------------------------|-----------------------------------------------|
| `await`-able non-blocking I/O          | `async def`                                    |
| Blocking I/O (no async client exists)  | `def` (sync — FastAPI runs it in a threadpool) |
| Mix of both                            | `async def` + `run_in_threadpool` for the blocking part |
| CPU-bound work (>50ms compute)         | Offload to a worker process (Celery / Arq / RQ) |

### Do / Don't

```python
# DON'T — blocking call inside an async route freezes the entire event loop,
# stalling every other request this worker is serving
@router.get("/bad")
async def bad():
    time.sleep(10)
    return {"ok": True}

# DO — sync route: FastAPI runs it in a threadpool, blocking one worker thread only
@router.get("/sync-ok")
def sync_ok():
    time.sleep(10)
    return {"ok": True}

# DO — async route with an awaitable
@router.get("/async-ok")
async def async_ok():
    await asyncio.sleep(10)
    return {"ok": True}

# DO — async route that must call a sync-only library
from fastapi.concurrency import run_in_threadpool

@router.get("/wrap")
async def wrap():
    result = await run_in_threadpool(legacy_sync_client.fetch, "id")
    return result
```

**Caveats**: Starlette's default threadpool is 40 threads — saturating it slows down every
sync route in the app. Threads cost more than coroutines; don't make a route `def` "just in
case," only when it genuinely does blocking I/O with no async equivalent.

## Background work — BackgroundTasks vs Celery/Arq/RQ

| Use `BackgroundTasks` when…                | Use Celery / Arq / RQ when…                  |
|---------------------------------------------|-------------------------------------------------|
| Task is < 1 second                          | Task takes seconds to minutes                    |
| Failure can be silently dropped             | You need retries, dead-letter, or visibility     |
| Task is in-process (send email, log a row)  | Task is CPU-heavy or needs a separate pool       |
| You don't need scheduling                   | You need cron, ETA, or rate limiting             |

```python
from fastapi import BackgroundTasks

@router.post("/signup")
async def signup(data: SignupIn, bg: BackgroundTasks):
    user = await service.create_user(data)
    bg.add_task(send_welcome_email, user.email)   # fire-and-forget, in-process
    return user
```

> `BackgroundTasks` run **after the response is sent, in the same worker process**. If the
> worker dies or restarts, the task is lost — no retry, no persistence. Never use it for
> anything you'd page on; reach for Celery/Arq/RQ instead.

## Dependency injection

### Use `Annotated`, not the default-argument form

`Annotated[T, Depends(...)]` is the idiomatic form since FastAPI 0.95 and avoids the
mutable-default-argument gotchas of the older style.

```python
# DO
from typing import Annotated
from fastapi import Depends

PostDep = Annotated[dict, Depends(valid_post_id)]

@router.get("/posts/{post_id}")
async def get_post(post: PostDep):
    return post

# Avoid — legacy default-arg form, still works but gotcha-prone
@router.get("/posts/{post_id}")
async def get_post(post: dict = Depends(valid_post_id)):
    return post
```

### Validate inside dependencies, not just inject

```python
async def valid_post_id(post_id: UUID4) -> dict:
    post = await service.get_by_id(post_id)
    if not post:
        raise PostNotFound()
    return post
```

### Chain dependencies for reuse

```python
async def valid_owned_post(
    post: Annotated[dict, Depends(valid_post_id)],
    token_data: Annotated[dict, Depends(parse_jwt_data)],
) -> dict:
    if post["creator_id"] != token_data["user_id"]:
        raise UserNotOwner()
    return post
```

### Rules

- Dependencies are **cached per request** — the same `Depends(x)` called 5 times in one
  request runs `x` once, not 5 times.
- Prefer `async def` dependencies. A sync dependency runs in the threadpool — wasted
  overhead for a small CPU-only check.
- Use the **same path-variable name** across endpoints when you want to share a dependency
  (e.g. `profile_id` in both `/profiles/{profile_id}` and `/creators/{profile_id}`).

## Database — SQLAlchemy 2.0 async

Use SQLAlchemy 2.0's async API (`AsyncSession`, `async_sessionmaker`). `encode/databases` is
in maintenance mode — don't pick it for new projects.

```python
# src/database.py
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

engine = create_async_engine(str(settings.DATABASE_URL), pool_pre_ping=True)
SessionFactory = async_sessionmaker(engine, expire_on_commit=False)

async def get_db() -> AsyncSession:
    async with SessionFactory() as session:
        yield session
```

### Naming conventions

- `lower_case_snake`, singular table names: `post`, `user`, `post_like`.
- Group related tables with a prefix: `payment_account`, `payment_bill`.
- `_at` suffix for `datetime` columns, `_date` suffix for `date` columns.
- Use the same FK column name everywhere it appears — not `user_id` in one table and
  `profile_id` in another for the same referenced entity.

```python
from sqlalchemy import MetaData

POSTGRES_INDEXES_NAMING_CONVENTION = {
    "ix": "%(column_0_label)s_idx",
    "uq": "%(table_name)s_%(column_0_name)s_key",
    "ck": "%(table_name)s_%(constraint_name)s_check",
    "fk": "%(table_name)s_%(column_0_name)s_fkey",
    "pk": "%(table_name)s_pkey",
}
metadata = MetaData(naming_convention=POSTGRES_INDEXES_NAMING_CONVENTION)
```

### SQL-first, Pydantic-second

Do joins, aggregation, and JSON shaping in SQL — Postgres is faster than CPython at this.
Hydrate into Pydantic only for response validation, not for transformation.

## Production deployment

### Uvicorn/Gunicorn worker config

Uvicorn alone is fine for local dev. In production, run it behind Gunicorn as a process
manager so a crashed worker gets replaced without taking the whole service down:

```shell
gunicorn src.main:app \
  -k uvicorn.workers.UvicornWorker \
  --workers 4 \
  --bind 0.0.0.0:8000 \
  --timeout 30 \
  --graceful-timeout 30
```

- **Worker count**: start at `(2 × CPU cores) + 1` as a baseline, then measure. FastAPI
  workers are I/O-bound event loops — each one already handles many concurrent requests
  via `asyncio`, so you rarely need as many workers as a sync WSGI app would.
- Don't run a single Uvicorn process directly in production with no supervisor — a single
  unhandled crash takes down 100% of capacity with nothing to restart it.
- Set `--timeout` to slightly above your slowest expected request, not the default; a
  timeout that's too low kills legitimate slow requests, one that's too high hides hangs.

### Lifespan handlers

Use the `lifespan` async context manager, not the deprecated `@app.on_event("startup")` /
`"shutdown"` decorators, to initialize and tear down shared resources (DB pool, HTTP
clients, caches).

```python
# DO
from contextlib import asynccontextmanager
from fastapi import FastAPI

@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.http_client = httpx.AsyncClient()
    yield
    await app.state.http_client.aclose()
    await engine.dispose()

app = FastAPI(lifespan=lifespan)

# DON'T — deprecated, and startup/shutdown aren't guaranteed to pair up under reload
@app.on_event("startup")
async def startup():
    app.state.http_client = httpx.AsyncClient()
```

### Health checks

Separate liveness from readiness — a liveness check that queries the database means a slow
DB takes your app out of rotation even though the process itself is fine.

```python
# DO — liveness: is the process alive? No dependency calls.
@router.get("/healthz")
async def healthz():
    return {"status": "ok"}

# DO — readiness: can this instance actually serve traffic?
@router.get("/readyz")
async def readyz(db: AsyncSession = Depends(get_db)):
    await db.execute(text("SELECT 1"))
    return {"status": "ok"}
```

Point your orchestrator's liveness probe at `/healthz` and readiness probe at `/readyz` —
conflating them causes cascading restarts when a dependency (not the app) is unhealthy.

### Graceful shutdown

On `SIGTERM`, Uvicorn stops accepting new connections and waits for in-flight requests to
finish before exiting — but only within `--timeout-graceful-shutdown` (Uvicorn) /
`--graceful-timeout` (Gunicorn). Set it above your p99 request latency, and make sure
`lifespan` teardown (closing DB engine, HTTP clients) actually runs — don't `os.exit` or
`kill -9` your own process from inside the app.

```shell
uvicorn src.main:app --timeout-graceful-shutdown 30
```

Don't rely on in-flight background tasks (`BackgroundTasks`) surviving shutdown — a worker
that receives `SIGTERM` mid-task and hits the graceful timeout is killed with the task
still running.

## Linting

Default to `ruff` for linting + formatting (replaces black, isort, autoflake, most of
flake8), and `mypy` for type checking:

```shell
ruff check --fix src
ruff format src
mypy src
```

**Always defer to the project's own `pyproject.toml`** if one already configures
`[tool.ruff]`, `[tool.black]`, or `[tool.mypy]` — don't overwrite or second-guess an
existing project's lint config with these defaults. These are only the starting point for
a project that has none.

## Anti-patterns

### Hard rules — always flag as violations

Correctness and reliability bugs. Flag these regardless of the project's age or existing
conventions — see [Scope](#scope).

| Anti-pattern | Why it's wrong | Fix |
|---|---|---|
| `requests.get(...)` inside `async def` | Blocks the event loop — `requests` is sync. | Use `httpx.AsyncClient` or `await run_in_threadpool(requests.get, ...)`. |
| `time.sleep` / `open()` / sync DB driver inside `async def` | Same — blocks the loop. | Use the async equivalent (`asyncio.sleep`, `aiofiles`, async driver). |
| `from jose import jwt` | `python-jose` is unmaintained. | `import jwt` (PyJWT). |
| `from async_asgi_testclient import TestClient` | Unmaintained. | `httpx.AsyncClient` + `ASGITransport`. |
| `model_config = ConfigDict(json_encoders={...})` | Deprecated in Pydantic v2. | `@field_serializer` or `Annotated[T, PlainSerializer(...)]`. |
| `Field(ge=18, default=None)` | The constraint and the default contradict each other. | Pick required (`Field(ge=18)`) or optional (`int \| None = Field(default=None, ge=18)`), not both. |
| `def get_user(id: int = Depends(...))` (default-arg form) | Legacy; gotchas with mutable defaults. | `user: Annotated[User, Depends(...)]`. |
| Catching bare `Exception` around a route's body | Hides bugs, turns real 500s into silent 200s. | Catch the specific exception class; raise `HTTPException` with a meaningful status. |
| `BackgroundTasks` for anything you'd page on | No retry, dies with the worker process. | Use Celery / Arq / RQ. |
| Calling a sync ORM session inside `async def` | Blocks the loop, may deadlock the connection pool. | Use `AsyncSession`. |
| Returning a Pydantic model *and* also setting `response_model=` to that same class | Model gets constructed twice (once to validate, once to serialize). | Return a `dict`/ORM row and let `response_model` validate, or drop `response_model` and trust the return type. |
| Mocking the database in integration tests | Mock/prod divergence eventually fires in prod. | Use a real DB (testcontainers, ephemeral schema) and `dependency_overrides` for auth/external services. |
| Running Uvicorn directly in prod with no process manager | One crash takes down all capacity. | Gunicorn + `UvicornWorker`, or an orchestrator that restarts the process. |
| `@app.on_event("startup"/"shutdown")` | Deprecated; doesn't guarantee pairing under reload. | `lifespan` async context manager. |
| Liveness probe that queries the DB | A slow dependency takes a healthy process out of rotation. | Liveness = process check only; readiness = dependency check. |

### Structural preferences — advisory, respect existing convention

These follow from the domain-based [project structure](#project-structure-structural-preference---advisory)
recommendation above. Don't flag them as violations in a project with an established,
different convention — note them only if asked to audit structure specifically, framed as
"this project uses X" rather than an error.

| Pattern | Domain-based rationale | If the project uses a different convention |
|---|---|---|
| Deep cross-domain imports (`from src.auth.service.user import ...`) instead of module-level (`from src.auth import service as auth_service`) | Tight coupling between domains, harder to refactor | Note it as "this project imports across modules via deep paths" — not a violation under a layered/other convention |
| One `BaseSettings` for the whole app instead of one per domain | Every domain ends up reading every env var; unclear ownership | Note it as "this project uses a single global settings object" — not a violation under a layered/monolithic convention |
