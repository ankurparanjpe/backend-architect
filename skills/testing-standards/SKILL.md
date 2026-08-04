---
name: testing-standards
description: >
  Cross-cutting backend testing rules that apply regardless of framework: test pyramid
  balance (unit tests for business logic, integration tests at I/O boundaries), test
  isolation and order independence, choosing fixtures vs mocks, which code paths must
  have tests before merge, and contract tests guarding response shapes that other
  services consume. Use when the work involves writing or restructuring tests, deciding
  what to mock or stub out, diagnosing a flaky or order-dependent test, judging whether
  a suite's coverage is adequate, or reviewing an existing test file — in any backend
  framework (FastAPI, Django, Flask, Express, etc.) or with no framework named at all.
  This skill owns the cross-cutting testing requirement itself; framework-specific
  test wiring (FastAPI's dependency_overrides, ASGI test clients, testcontainers setup,
  and the existing rule against mocking the database in an integration test) lives in the
  sibling framework skill (fastapi-architecture, django-architecture, flask-architecture)
  and is cross-referenced from here rather than restated. Does not cover production
  logging or exception reporting (see backend-observability), the auth and
  input-validation rules themselves (see backend-security), cache correctness (see
  backend-caching), or runtime performance tuning (see backend-performance).
---

# Testing Standards

Cross-cutting testing rules for backend services, independent of framework. Applies
alongside framework-specific skills (fastapi-architecture, django-architecture,
flask-architecture) rather than replacing them — this skill covers *what* a test suite
must guarantee; the framework skill covers *how* to wire tests in that framework.

## Scope

This skill enforces two different kinds of rules:

- **Hard rules** — testing gaps that let real bugs reach production: an integration test
  that mocks the very boundary it exists to exercise, tests that depend on execution
  order or shared mutable state between tests, business logic mocked out to force a pass,
  critical paths (auth, payment, data mutation) with no test at all, and a
  consumer-facing response shape changed with no contract test guarding it. These are
  flagged as violations regardless of the project's age or existing conventions.
- **Structural preferences** — organizational recommendations: test framework choice
  (pytest vs unittest), coverage-percentage targets, and test file layout/naming. These
  are advisory only — a coverage number is a project/team decision this skill does not
  prescribe, and a project consistently using a different runner is not a violation. If a
  project has an established convention that differs, don't flag it as a violation — note
  it only if asked to audit structure specifically.

## Test pyramid balance

Two test kinds, two different jobs:

- **Unit tests** exercise business logic — the decisions, calculations, and branching
  that produce a result from inputs. Fast, no I/O, no network, no database.
- **Integration tests** exercise I/O boundaries — that the query returns what the code
  expects, that the migration applies, that the third-party client parses a real
  response shape. Slower by nature, because the whole point is the real boundary.

**Hard rule**: an integration test must not mock the boundary it exists to test. A test
named `test_order_repository_saves` that replaces the database with a `MagicMock` proves
only that Python can call a method — it passes with a broken query, a missing column, a
failed migration, and a wrong transaction scope. It tests the mock, not the boundary.

```python
# DON'T — claims to be an integration test, then removes the only thing it
# integrates with; passes even if the column was dropped or the SQL is invalid
async def test_repository_saves_order(monkeypatch):
    fake_session = MagicMock()
    repo = OrderRepository(session=fake_session)
    await repo.save(Order(user_id=1, total=100))
    assert fake_session.add.called  # asserts on the mock's own bookkeeping

# DO — real database (ephemeral schema or a container), assert on read-back state
async def test_repository_saves_order(db_session):
    repo = OrderRepository(session=db_session)
    await repo.save(Order(user_id=1, total=100))
    stored = await db_session.get(Order, 1)
    assert stored.total == 100
```

This is the cross-cutting form of a rule the framework skill already owns for FastAPI:
see fastapi-architecture § Anti-patterns → "Mocking the database in integration tests"
for the FastAPI mechanism (testcontainers, ephemeral schema, `dependency_overrides`
scoped to auth and external services *only*). The framework skill also owns test-client
choice (`httpx.AsyncClient` + `ASGITransport`), which this skill does not restate.

Don't invert the pyramid in either direction. Routing every test through the full HTTP
stack and a real database makes a suite too slow to run per-commit, so it stops being
run — pure business logic doesn't need a database to be tested. Mocking every boundary
makes a fast suite that never fails on the bugs that actually happen. Business logic
gets unit tests; boundaries get real integration tests.

## Test isolation

**Hard rule**: every test passes when run alone, and the suite passes in any order.
A test that depends on an earlier test having run — for state, for a created row, for a
mutated module-level value — is not a test, it's one half of a hidden test that fails
whenever the runner shards, parallelises, randomises, or someone runs a single test to
debug it. Order-dependent tests are the mechanism behind most "flaky" suites.

```python
# DON'T — module-level mutable state shared across tests; test_list_users only
# passes if test_create_user ran first, and running it alone fails
CREATED_USERS = []

def test_create_user(client):
    resp = client.post("/users", json={"email": "a@example.com"})
    CREATED_USERS.append(resp.json()["id"])
    assert resp.status_code == 201

def test_list_users(client):
    resp = client.get("/users")
    assert resp.json()[0]["id"] == CREATED_USERS[0]

# DO — each test creates the state it needs and cleans up; passes alone, in any order
def test_list_users(client, created_user):
    resp = client.get("/users")
    assert created_user["id"] in [u["id"] for u in resp.json()]
```

The same applies to state outside the process: a test that leaves rows, cache keys, or
files behind is coupling every later test to its own success. Roll back the transaction,
truncate, or use a fresh schema/namespace per test.

## Fixtures vs mocks

They solve different problems, and swapping one for the other is where suites go wrong:

- **Fixtures** build realistic, reusable state the test needs to be meaningful — a
  seeded user, an open database session, a configured client. Use a fixture whenever
  several tests need the same setup.
- **Mocks/stubs** stand in for a dependency you can't or shouldn't invoke in a test —
  a payment provider, an email sender, a third-party HTTP service, wall-clock time.
  The boundary is: is it *outside* the code under test *and* outside your control?

**Hard rule**: don't mock your own business logic to make a test pass. Patching the
function under test — or the internal function it delegates to — deletes the assertion.
The test then asserts that the mock returned what you told it to return.

```python
# DON'T — the discount rule IS the thing under test; patched out, this asserts nothing
def test_checkout_applies_discount(monkeypatch):
    monkeypatch.setattr("billing.service.calculate_discount", lambda o: 10)
    assert checkout(order).total == 90

# DO — mock only the external boundary (the payment provider); let your own logic run
def test_checkout_applies_discount(monkeypatch, order_fixture):
    monkeypatch.setattr("billing.service.payment_gateway.charge", lambda *a: "ch_123")
    assert checkout(order_fixture).total == 90  # real calculate_discount ran
```

If a mock is the only way to get a test green, the test is telling you the code under
test is hard to isolate — extract the logic so it can be called with plain inputs,
rather than mocking until the assertion is vacuous.

## What must have test coverage

**Hard rule**: critical paths have tests. A path is critical when a silent failure costs
money, data, or access:

- **Authentication and authorization** — login, token issuance/refresh, and every
  permission check. Especially the negative cases: the wrong user, the expired token,
  the missing scope. A permission check with only a happy-path test is untested.
- **Payment and billing** — charges, refunds, amount calculation, idempotency on retry.
- **Data mutation** — writes, updates, and deletes, including the failure path (does a
  partial failure roll back?). A destructive operation with no test is the one that
  eventually runs against the wrong rows.

These are the paths where "we'll notice in staging" is false — an authorization bug
looks exactly like working software until someone reads data they shouldn't.

*What the coverage number should be is not a hard rule* — see
[Advisory: coverage targets](#advisory-coverage-targets).

## Contract testing

**Hard rule**: if another service consumes your API, its response shape is a contract,
and a change to that shape is a breaking change that needs a test guarding it — not a
manual check before release. Renaming a field, changing a type, making an optional field
required, or removing a value from an enum breaks every consumer that parsed the old
shape, and nothing in your own suite notices if the tests only assert on status codes.

```python
# DON'T — passes after any field rename, type change, or removal
def test_get_order(client):
    resp = client.get("/orders/1")
    assert resp.status_code == 200

# DO — the promised shape is asserted, so a rename fails here instead of in the consumer
def test_get_order_contract(client):
    body = client.get("/orders/1").json()
    assert set(body) >= {"id", "status", "total_cents", "created_at"}
    assert isinstance(body["total_cents"], int)
    assert body["status"] in {"pending", "paid", "cancelled"}
```

A schema snapshot (asserting the generated OpenAPI schema for the endpoint matches a
committed copy) covers the whole surface in one test and fails loudly on any shape
change — which is the goal: make the break visible in *your* CI, at the moment of the
change, rather than in the consumer's error tracker a week later. When a change is
genuinely intended, updating the guarding test is the deliberate act that records it.

## Advisory: test framework choice

pytest is the de facto default in the FastAPI/modern-Python ecosystem and is worth
recommending for a new project: fixtures with dependency injection, parametrisation, and
plain `assert` statements. `pytest-asyncio` covers async test functions.

This is a preference, not a hard rule. A project consistently using `unittest`,
`nose2`, or anything else is not a violation — the rules in this skill (pyramid balance,
isolation, mock discipline, critical-path coverage, contract guarding) are all
expressible in any runner. Don't propose a migration; don't flag the choice.

## Advisory: coverage targets

**This skill prescribes no coverage percentage.** A number is a project and team
decision, and the right one depends on what the codebase is. Chasing a global percentage
also actively misleads: a suite at 90% can leave every authorization branch untested
while covering getters and generated boilerplate.

What is a hard rule is *which paths* need tests (see
[What must have test coverage](#what-must-have-test-coverage)). Coverage tooling is most
useful pointed at those paths — a report showing an untested `else` in a permission
check is worth more than any suite-wide target. If a project has a configured threshold,
respect it; don't flag the number, and don't propose one where none exists.

## Anti-patterns

### Hard rules — always flag as violations

Correctness and reliability gaps. Flag these regardless of the project's age or existing
conventions — see [Scope](#scope).

| Anti-pattern | Why it's wrong | Fix |
|---|---|---|
| Integration test that mocks the boundary it exists to test (DB, queue, third-party client replaced by a mock) | Passes with a broken query, missing column, or unapplied migration — it asserts on the mock's own bookkeeping, not the boundary. | Exercise the real boundary (ephemeral schema/container) and assert on read-back state; mock only auth and unrelated external services. For the FastAPI mechanism, see fastapi-architecture § Anti-patterns → "Mocking the database in integration tests". |
| Test that only passes when another test ran first (shared module-level mutable state, ordering assumptions) | Fails the moment the suite is sharded, parallelised, randomised, or a single test is run to debug it — this is what a "flaky" suite usually is. | Each test creates the state it needs via a fixture and cleans up (transaction rollback, truncate, fresh namespace); every test must pass in isolation. |
| Test leaves persistent state behind (rows, cache keys, files) with no teardown | Couples every later test to this one's success, and to run order. | Roll back / truncate / use a per-test schema or key namespace in a fixture's teardown. |
| Patching the code under test — or its internal helper — to make a test pass | Deletes the assertion: the test now verifies that the mock returns what it was told to. | Mock only dependencies outside the code under test and outside your control; extract logic so it can be called with plain inputs instead. |
| Critical path (auth/authorization, payment, data mutation) with no test | A silent failure on these paths costs money, data, or access, and looks exactly like working software until it doesn't. | Test them, negative cases included: wrong user, expired token, missing scope, partial-failure rollback. |
| Consumer-facing response shape changed with no test asserting that shape | Renames, type changes, and removed fields break every consumer that parsed the old shape; a status-code-only test notices nothing. | Assert the promised field names, types, and enum values — or snapshot the endpoint's generated schema against a committed copy. |

### Structural preferences — advisory, respect existing convention

| Pattern | Rationale | If the project uses a different convention |
|---|---|---|
| pytest as the test runner (with `pytest-asyncio` for async tests) | Ecosystem default, but every rule above is expressible in any runner. | Don't flag; a project consistently on `unittest` or another runner is fine. Don't propose a migration. |
| A specific coverage percentage target | Project/team decision; a global number can be high while critical branches stay untested. | Don't flag, and don't propose a number where none exists. Respect a configured threshold if one is set. |
| Test file layout and naming (`tests/` mirroring `src/`, `test_*.py` vs `*_test.py`) | Organizational choice with no correctness consequence. | Don't flag; follow whatever the project already does. |
