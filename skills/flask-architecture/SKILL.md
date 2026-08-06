---
name: flask-architecture
description: >
  Flask-specific production architecture rules: application factory pattern (create_app())
  as the recommended default vs a module-level Flask() instance, Blueprints for domain
  separation, Flask-SQLAlchemy/Flask-Migrate extension init and the circular-import
  footgun between extensions and the factory, Marshmallow/Pydantic input validation in
  place of Flask's lack of built-in serializers, class-based config vs scattered
  os.environ.get() calls, async-view support (2.0+) and where blocking calls still creep
  in, and an anti-patterns checklist for reviewing Flask code. Use when the project
  imports `from flask import Flask`, instantiates `Flask(__name__)`, uses
  `@app.route`/`Blueprint`, Flask-SQLAlchemy, or Flask-RESTful/Flask-RESTX. Do not use for
  generic backend security, observability, caching, performance, resilience, or testing
  questions with no Flask signal — those are covered by the sibling backend-security /
  backend-observability / backend-caching / backend-performance / resilience-patterns /
  testing-standards skills in this plugin.
---

# Flask Architecture

Production-grade rules for Flask services. Assumes Flask ≥ 2.3, Flask-SQLAlchemy ≥ 3.0,
Python ≥ 3.11.

## Scope

Flask is deliberately minimal — it has no built-in equivalent to Django's apps or
FastAPI's dependency-injected structure enforcing shape on a project. Most of what
follows below is convention this skill recommends, not something the framework itself
enforces or breaks without. A few things still get flagged as hard rules despite that,
because they're correctness bugs, not layout preferences, even though nothing in Flask
stops you from writing them:

- **Hard rules** — blocking calls inside an `async def` view, hardcoded config values,
  and raw `request.get_json()` used with no schema validation. Flagged regardless of the
  project's age or existing conventions.
- **Structural preferences** — the `create_app()` application factory, Blueprint-per-domain
  layout, config class hierarchy, file structure inside a Blueprint. Advisory only. If a
  project already has an established
  convention that differs — one monolithic Blueprint, a different config pattern — don't
  flag it as a violation; note it only if asked to audit structure specifically, framed
  as "this project uses X instead of Y," not as an error. The recommendations below are
  for a project starting fresh with no existing convention, not a migration target for
  an established codebase.

## Application factory pattern (structural preference — advisory)

> Advisory, not a hard rule — see [Scope](#scope).

The application factory pattern (`create_app()`) is recommended for testability and config
isolation, especially in larger applications. However, a module-level app is acceptable for
small, single-config services with no separate test suite requirements. This is a
structural preference, not a correctness rule.

```python
# ACCEPTABLE for a small single-config service, but note the ceiling: config is
# fixed at import time, and every test that imports this module gets the same app
# with no way to swap config or register a fresh extension set for isolation
app = Flask(__name__)
app.config["SQLALCHEMY_DATABASE_URI"] = "postgresql://prod-host/app"

@app.route("/health")
def health():
    return {"ok": True}

# PREFERRED — factory: config is a parameter, extensions attach to whatever
# instance the caller builds
def create_app(config_class=ProdConfig):
    app = Flask(__name__)
    app.config.from_object(config_class)
    db.init_app(app)
    app.register_blueprint(health_bp)
    return app
```

What the factory buys, and therefore when the module-level form starts costing you:

- **Testing.** A test suite needs an app built against `TestConfig` (a throwaway/in-memory
  DB, `TESTING=True`) without touching the production instance. A module-level `Flask()`
  gives every test the same app, config baked in at import time.
- **Multiple configs from one codebase.** Dev, staging, and prod need different config
  objects; a factory takes the config as a parameter instead of branching on an
  environment variable read at import time.
- **Extension init order.** Extensions (`db`, `migrate`, a cache client) are created at
  module scope with no app bound, then attached inside the factory via `.init_app(app)` —
  see [Extensions pattern](#extensions-pattern) below. That two-step split only works
  inside a factory; there's no second "attach" step for a module-level app.

## Blueprints for domain separation (structural preference — advisory)

> Advisory, not a hard rule — see [Scope](#scope). This is the recommended layout for a
> **new** Flask project with no established convention. If an existing project already
> organizes routes differently — one flat `app.py`, a single Blueprint for the whole API —
> don't flag deviations from this section as violations; only note them if asked to audit
> structure specifically.

Blueprints are the closest Flask analogue to FastAPI's `APIRouter` or a Django app — a
named, independently-registerable slice of routes. Unlike a Django app, a Blueprint
carries no migrations, no models directory, no admin — it's routing and view organization
only, so the rest of a domain's structure (models, schemas, services) is a convention this
skill recommends, not something Flask itself attaches to the Blueprint boundary.

Recommend one Blueprint per bounded domain for a fresh project:

```
src/
├── orders/
│   ├── routes.py       # Blueprint + view functions
│   ├── models.py       # Flask-SQLAlchemy models
│   ├── schemas.py      # Marshmallow/Pydantic schemas
│   └── services.py     # business logic
├── billing/
│   └── ...
├── extensions.py        # db = SQLAlchemy(), migrate = Migrate(), etc. — no app bound yet
├── config.py             # Config / DevConfig / ProdConfig
└── app.py                # create_app()
```

```python
# src/orders/routes.py
from flask import Blueprint

orders_bp = Blueprint("orders", __name__, url_prefix="/orders")

@orders_bp.route("/<int:order_id>")
def get_order(order_id):
    ...

# src/app.py
from src.orders.routes import orders_bp

def create_app(config_class=ProdConfig):
    app = Flask(__name__)
    app.config.from_object(config_class)
    app.register_blueprint(orders_bp)
    return app
```

A single Blueprint (or none at all) for a small app with a handful of routes is a
legitimate choice, not a violation — don't push the Blueprint-per-domain split onto a
project that doesn't need it yet, and don't flag an established different split (by
technical layer, one Blueprint for the whole API) as wrong.

## Async views — an escape hatch, not a posture

Flask has supported `async def` views since 2.0, but Flask is not async-first the way
FastAPI is. Sync is still the default: Werkzeug's dev server and most production
deployments (Gunicorn sync/gthread workers) run each request on its own thread rather
than an event loop, and the majority of Flask codebases have zero async views and never
will. That's not a gap to flag — unlike FastAPI, where an all-sync route set is worth
questioning, a Flask project with no async anywhere is just a normal Flask project, and
recommending someone add `async def` "for performance" is a FastAPI reflex that doesn't
transfer here. Async in Flask exists for one narrow case: a view that needs to `await` an
async-only client without restructuring the whole app around an event loop, and it
requires the `flask[async]` extra (`asgiref`) to run at all.

The one thing that carries over unchanged: a view that *does* opt into `async def` and
then puts a blocking call inside it (`requests.get()`, `time.sleep()`, a sync DB driver)
stalls the event loop Flask spins up to run that view — same hazard the other two skills
flag, flag it the same way here.

```python
# DON'T — async def view, but the body is entirely blocking; gains nothing
# over a plain sync view and still stalls the event loop Flask created for it
@orders_bp.route("/sync-report")
async def sync_report():
    resp = requests.get("https://partner.example.com/report")  # blocking
    return resp.json()

# DO — plain sync view; this is the normal, unremarkable case
@orders_bp.route("/sync-report")
def sync_report():
    resp = requests.get("https://partner.example.com/report")
    return resp.json()

# DO — async view, used for what async is actually for: awaiting an
# async-only client
@orders_bp.route("/async-report")
async def async_report():
    async with httpx.AsyncClient() as client:
        resp = await client.get("https://partner.example.com/report")
    return resp.json()
```

## Extensions pattern

**The circular-import footgun**: an extension instance (`SQLAlchemy()`, `Migrate()`)
needs to be importable from anywhere a model or route references it, but it also needs an
app to bind to — and the app is built inside `create_app()`, which is exactly where a
naive import cycle forms if the extension is created *inside* the factory and models
import it back from there.

**Hard rule**: extension instances are created at module scope with no app bound, then
attached to the app instance via `.init_app(app)` inside the factory. This is Flask's own
documented two-step pattern for this reason.

```python
# src/extensions.py — created with no app; safe to import from anywhere
from flask_sqlalchemy import SQLAlchemy
from flask_migrate import Migrate

db = SQLAlchemy()
migrate = Migrate()

# src/orders/models.py — imports the bare instance, never the app
from src.extensions import db

class Order(db.Model):
    id = db.Column(db.Integer, primary_key=True)

# src/app.py — binds the extensions to this app instance
from src.extensions import db, migrate

def create_app(config_class=ProdConfig):
    app = Flask(__name__)
    app.config.from_object(config_class)
    db.init_app(app)
    migrate.init_app(app, db)
    from src.orders.routes import orders_bp   # import here, after extensions are bound
    app.register_blueprint(orders_bp)
    return app
```

```python
# DON'T — SQLAlchemy() created inside create_app() has no module-level name
# for models.py to import; models.py either imports create_app (circular:
# app.py imports models via the blueprint, models imports the factory back)
# or duplicates a second SQLAlchemy() instance that never gets bound
def create_app():
    app = Flask(__name__)
    db = SQLAlchemy(app)   # only reachable from inside this function
    from src.orders.models import Order   # Order can't import `db` from here
    return app
```

Blueprint imports inside `create_app()` (rather than at module top-level in `app.py`) are
deliberate, not sloppy — importing a Blueprint module at the top of `app.py` runs its
`from src.extensions import db` before `db.init_app(app)` has executed for some import
orders, resurfacing the same cycle one level up.

## Input validation — no built-in serializer

**Hard rule**: `request.get_json()` (or `request.form`/`request.args`) read directly into
business logic or the ORM with no schema validation is a violation, the same class of bug
as FastAPI/Django's input-validation hard rules — Flask just has no Pydantic/DRF layer
doing it for you, so an unvalidated read is a real and common mistake rather than
something the framework prevents.

```python
# DON'T — no type coercion, no required-field check, no bounds; a missing
# key is a KeyError 500, a wrong type is whatever the DB does with it
@orders_bp.route("/", methods=["POST"])
def create_order():
    data = request.get_json()
    order = Order(sku=data["sku"], quantity=data["quantity"])
    db.session.add(order)
    db.session.commit()
    return {"id": order.id}

# DO — Marshmallow: validate, then read from the validated dict
class OrderCreateSchema(Schema):
    sku = fields.Str(required=True, validate=validate.Length(max=32))
    quantity = fields.Int(required=True, validate=validate.Range(min=1, max=1000))

@orders_bp.route("/", methods=["POST"])
def create_order():
    payload = OrderCreateSchema().load(request.get_json())   # raises ValidationError -> 400
    order = services.place_order(**payload)
    return {"id": order.id}

# DO — Pydantic works equally well; validate() raising becomes the 400 path
class OrderCreate(BaseModel):
    sku: str = Field(max_length=32)
    quantity: int = Field(ge=1, le=1000)

@orders_bp.route("/", methods=["POST"])
def create_order():
    payload = OrderCreate.model_validate(request.get_json())
    order = services.place_order(**payload.model_dump())
    return {"id": order.id}
```

Pick one library per project and use it consistently — Marshmallow if the project is
already Flask-ecosystem-native (Flask-RESTX ships Marshmallow-style parsing), Pydantic if
the team already uses it elsewhere (another service, a shared schema package). Don't flag
the choice itself; flag the absence of either.

A Marshmallow `ValidationError` (or Pydantic's `ValidationError`) needs a registered
`@app.errorhandler` to turn into a `400` with field errors — uncaught, it's an unhandled
exception and a `500`. See backend-security § Error responses for the shape that error
body should take.

## Config management

**Hard rule**: no hardcoded config value (a DB URL, an API key, a secret) in source.
Advisory, not hard: *how* config is organized once it's out of source.

```python
# DON'T — hardcoded, and scattered os.environ.get() calls with no single
# source of truth for what config keys exist or what their defaults are
app.config["SQLALCHEMY_DATABASE_URI"] = "postgresql://prod-host/app"
SECRET = os.environ.get("SECRET_KEY", "dev-secret")   # silent fallback in prod too

# DO (structural preference) — class-based config, one class per environment
class Config:
    SQLALCHEMY_DATABASE_URI = os.environ["DATABASE_URL"]
    SECRET_KEY = os.environ["SECRET_KEY"]

class DevConfig(Config):
    DEBUG = True

class ProdConfig(Config):
    DEBUG = False

app.config.from_object(ProdConfig)
```

The class hierarchy is advisory — a project that reads config through a different
mechanism (a `pydantic-settings` object, a single flat `Config` with no subclasses) isn't
wrong for doing so; the hard rule is only that the *value* isn't a literal in source and
doesn't silently fall back to a development default in a context that might be production.

## N+1 / response shaping — Flask-SQLAlchemy's lazy loading

backend-performance owns the cross-cutting rule (a loop issuing one query per row of an
earlier result); this is the Flask-specific mechanism. Flask-SQLAlchemy relationships
default to lazy (`lazy="select"`) — the same attribute-access-looks-free trap as Django's
ORM, with no `await` at the call site to flag it in review.

```python
# DON'T — 1 query for orders, then one more per order for its items
orders = Order.query.all()
for order in orders:
    print(len(order.items))          # query per row

# DO — eager-load in the original query
from sqlalchemy.orm import selectinload

orders = Order.query.options(selectinload(Order.items)).all()
for order in orders:
    print(len(order.items))          # already loaded, no new query
```

`selectinload` (one extra query total, best default for one-to-many) and `joinedload`
(single query via `JOIN`, better for to-one) are the same SQLAlchemy 2.0-style options
fastapi-architecture documents — see fastapi-architecture § N+1 prevention for the
async-session version of the same mechanism. Response field projection follows the same
principle as the other two skills: don't serialize a full ORM row with `jsonify(order.__dict__)`
or a schema that mirrors every column; project explicitly through the Marshmallow/Pydantic
schema used for validation above.

## Anti-patterns

### Hard rules — always flag as violations

Correctness and reliability bugs. Flag these regardless of the project's age or existing
conventions — see [Scope](#scope).

| Anti-pattern | Why it's wrong | Fix |
|---|---|---|
| Extension instantiated with an app bound inside the factory (`SQLAlchemy(app)` inside `create_app()`) — applies to projects that use a factory | Models can't import a module-level instance that doesn't exist yet — circular import or a second unbound instance. | Create the extension bare at module scope (`db = SQLAlchemy()`), bind with `db.init_app(app)` inside the factory. |
| Blocking call (`requests.get`, `time.sleep`, sync DB driver) inside an `async def` view | Stalls the event loop Flask spins up to run that view — same hazard as FastAPI/Django's async rule. | Use an async client (`httpx.AsyncClient`), or don't make the view `async def` if it's not awaiting anything async. Either way the call needs an explicit timeout — see resilience-patterns § Timeouts on every external call. |
| `request.get_json()` (or `.form`/`.args`) read directly into business logic or the ORM with no schema | No type coercion, no required-field check, no bounds; missing key is a 500, wrong type is whatever the DB does with it. | Marshmallow or Pydantic schema at the view boundary; read only the validated result. |
| Hardcoded DB URL / API key / secret in source, or `os.environ.get("SECRET", "fallback")` | Committed to history; the fallback form silently ships a known value if the env var is ever unset in production. | Read from environment with no default (`os.environ["KEY"]`), fail loudly if absent. See backend-security § Secrets management. |
| Relation attribute accessed per row of a `.query.all()`/`.all()` result with no eager loading | N+1 — 1 request becomes 1+N round trips, scaling with result size. | `selectinload`/`joinedload` in the original query. |
| `jsonify(model.__dict__)` or a schema mirroring every column | Serializes fields the response contract never promised. | Explicit Marshmallow/Pydantic schema projecting only the contract's fields. |
| Unhandled `ValidationError` from the schema library | Uncaught exception becomes a bare 500 instead of a 400 with field errors. | Register `@app.errorhandler` for the schema library's validation exception. |

### Structural preferences — advisory, respect existing convention

These follow from the application-factory and
[Blueprint-per-domain](#blueprints-for-domain-separation-structural-preference--advisory)
recommendations above. Don't flag them as violations in a project with an established,
different convention — note them only if asked to audit structure specifically, framed as
"this project uses X" rather than an error.

| Pattern | Rationale | If the project uses a different convention |
|---|---|---|
| `app = Flask(__name__)` at module scope instead of a `create_app()` factory | A factory keeps config a parameter, so tests can build an app against `TestConfig` and dev/staging/prod differ by argument rather than by import-time branching | Note it as "this project uses a module-level app" — not a violation for a small, single-config service with no separate test-suite config; recommend the factory when a test suite or a second config appears |
| One flat `app.py`/`routes.py` with every route, no Blueprints | Fine for a small app; becomes unclear ownership as routes grow past a handful | Note it as "this project uses a single flat route module" — not a violation for a small or established codebase |
| A single Blueprint for the whole API instead of one per domain | Loses the domain boundary Blueprints exist to express | Note it as "this project uses one Blueprint for the whole API" — not a violation under an established convention |
| Config read via scattered `os.environ.get()` calls instead of a `Config` class hierarchy | No single source of truth for what config keys exist or their defaults | Note it as "this project reads config via scattered env lookups" — not a violation as long as no value is hardcoded (that part is the hard rule) |
| Marshmallow in one part of the app, Pydantic in another | Two validation libraries to reason about instead of one | Note it as "this project mixes validation libraries" — not a violation; only the *absence* of either is the hard rule |
