---
name: django-architecture
description: >
  Django-specific production rules: one `startapp` app per bounded context, why sync views
  stay the default and what breaks when a sync ORM call lands in an `async def` view, DRF
  serializers validating at the view edge rather than deeper in `request.data` handling,
  `select_related`/`prefetch_related` eager loading, explicit `Meta.fields` on response
  serializers, `settings.py` hardening (`DEBUG`, `SECRET_KEY`, `ALLOWED_HOSTS`, CSRF
  middleware, the `--deploy` settings audit), migration discipline (`makemigrations`/`migrate`, never
  touching an applied migration, `apps.get_model` in data migrations), plus a table of
  Django violations to flag. Use for a repo with `manage.py`, a `settings.py` declaring
  `INSTALLED_APPS`, models declared via `django.db.models`, Django ORM querysets
  (`Model.objects`, `QuerySet`), or Django REST Framework (`rest_framework`,
  `ModelSerializer`, `ViewSet`). Do not use for generic backend security, observability,
  caching, or performance questions with no Django signal — those are covered by the
  sibling backend-security / backend-observability / backend-caching /
  backend-performance skills in this plugin.
---

# Django Architecture

Production-grade rules for Django services. Assumes Django ≥ 4.2 (LTS), Django REST
Framework ≥ 3.15, Python ≥ 3.11.

## Scope

This skill enforces two different kinds of rules:

- **Hard rules** — correctness and reliability issues: a sync ORM call inside an
  `async def` view, missing eager loading that turns one request into N+1 queries,
  `DEBUG = True` or a hardcoded `SECRET_KEY` reaching production, `@csrf_exempt` on a
  session-authenticated write, editing a migration that has already been applied. These
  are bugs rather than style choices, and are flagged as violations regardless of the
  project's age or existing conventions.
- **Structural preferences** — organizational recommendations: how domains map onto
  Django apps, where business logic lives relative to views, file layout inside an app.
  These are advisory only. If a project already has an established app layout that
  differs from the recommendation below, don't flag it as a violation — note it only if
  asked to audit structure specifically, and frame it as "this project organizes apps by
  X instead of by bounded domain," not as an error. The one-app-per-domain structure is a
  recommendation for projects starting fresh with no existing convention, not a migration
  target for established codebases.

## Project structure — one app per bounded domain (structural preference — advisory)

> Advisory, not a hard rule — see [Scope](#scope). This is the recommended layout for a
> **new** Django project with no established convention. If an existing project already
> organizes its apps differently, don't flag deviations from this section as violations;
> only note them if asked to audit structure specifically.

Create one app per bounded domain — `python manage.py startapp orders`, `startapp
billing`, `startapp accounts` — rather than one app holding every model in the project, or
apps split by technical layer (`api`, `models`, `services`).

This isn't a layout preference imported from another framework. Django's own unit of
composition **is** the app, and the framework's mechanics are attached to it:

- `INSTALLED_APPS` registers apps, not folders.
- Migrations are per-app, under `<app>/migrations/`, with their own linear history.
- `AppConfig.ready()` is the app-scoped startup hook (signal registration, checks).
- Template and static-file resolution is app-relative.
- Every model carries an `app_label`; moving a model between apps is a migration event,
  not a file move.

So the boundary has consequences. A domain spread across two apps splits its migration
history. Two domains inside one app share one migration timeline and can't be pulled apart
later without a rename-and-state-operation dance. Picking the app boundary to match the
domain boundary is what keeps that cheap.

```
myproject/
├── manage.py
├── config/                 # project package: settings, root urls, wsgi/asgi
│   ├── settings/
│   │   ├── base.py
│   │   ├── dev.py
│   │   └── prod.py
│   ├── urls.py
│   └── asgi.py
├── orders/                 # one bounded domain = one app
│   ├── apps.py
│   ├── models.py
│   ├── serializers.py      # DRF convention
│   ├── views.py
│   ├── urls.py
│   ├── admin.py
│   ├── services.py         # optional — see below
│   └── migrations/
└── billing/
    └── ...
```

Most filenames here are Django's, not this skill's — `models.py`, `views.py`, `admin.py`,
`apps.py`, `migrations/` come from the framework. `serializers.py` is DRF's own convention.

**`services.py` is genuinely optional.** "Fat models, thin views" — domain logic as model
methods, managers, and querysets — is an equally legitimate established Django convention,
and often the better fit for a project whose logic is naturally row-scoped. Don't flag a
project for having no service layer. The rule that matters is that logic isn't in the view;
where it goes instead is the project's call.

**Cross-app access is a hard rule, not a preference.** A view or service in one app
reaching directly into another app's models couples the two at the schema level, so a
change to one app's internals breaks the other silently:

```python
# DON'T — billing reaches into orders' schema; any change there breaks billing
from orders.models import Order

def compute_invoice(user):
    rows = Order.objects.filter(user=user, status="shipped")

# DO — go through the owning app's public surface
from orders import services as order_services

def compute_invoice(user):
    rows = order_services.shipped_orders_for(user)
```

`ForeignKey` across apps is fine and expected — that's a declared relationship, not a
reach-through. The rule is about behavior and queries, not about the schema graph.

## Async in Django — sync is still the common case

Django supports `async def` views (since 3.1) and an async ORM interface (`acreate`,
`aget`, `asave`, `async for`, since 4.1). It is **not** async-by-default, and most
production Django is sync — running under WSGI, with sync views and sync ORM calls, which
is entirely correct and needs no migration.

Don't recommend converting a working sync Django project to async. Sync views are the
default for a reason: the ORM's sync path is the mature one, and a WSGI deployment with
enough workers handles ordinary request/response load fine.

| Situation | What to use |
|---|---|
| Ordinary request/response, ORM + template/JSON | Sync `def` view under WSGI. The default. |
| Many concurrent slow outbound HTTP calls in one view | `async def` view under ASGI + an async HTTP client |
| Long-running or retryable work | Celery / Django-Q / RQ, not a view at all |
| Async view that must touch the ORM | ORM `a*` methods, or `sync_to_async` — see below |

### Hard rule: no sync ORM call inside an `async def` view

This is Django's equivalent of FastAPI's blocking-call rule (see fastapi-architecture
§ Async vs sync routes). A sync ORM call inside `async def` blocks the event loop for the
duration of the query, stalling every other request that worker is serving.

Django detects most of these and raises `SynchronousOnlyOperation` — but not all of them.
Lazy evaluation means the query fires wherever the `QuerySet` is first consumed, which can
be in a template render, a serializer, or an `if queryset:` truthiness check far from the
line that looks like the database access.

```python
# DON'T — sync ORM inside an async view: blocks the loop (and usually raises
# SynchronousOnlyOperation, but not reliably — a lazy QuerySet can escape the
# view and evaluate somewhere else entirely)
async def order_detail(request, order_id):
    order = Order.objects.get(pk=order_id)
    return JsonResponse({"id": order.id, "status": order.status})

# DO — async ORM interface
async def order_detail(request, order_id):
    order = await Order.objects.aget(pk=order_id)
    return JsonResponse({"id": order.id, "status": order.status})

# DO — async iteration over a queryset
async def order_list(request):
    rows = [{"id": o.id} async for o in Order.objects.all()[:100]]
    return JsonResponse({"results": rows})

# DO — wrap sync-only code (third-party lib, ORM path with no async equivalent)
from asgiref.sync import sync_to_async

async def report(request):
    data = await sync_to_async(build_legacy_report, thread_sensitive=True)()
    return JsonResponse(data)
```

**`thread_sensitive=True` is the default and usually what you want** — it runs the wrapped
callable in a single shared thread, which is what keeps ORM connection and transaction
state coherent. Setting `thread_sensitive=False` for ORM work risks running inside a
transaction opened on a different thread.

**Also a hard rule: no sync ORM inside `atomic()` across an async boundary.**
`transaction.atomic()` is thread-local and sync-only; an `async def` view can't wrap
`await`ed work in it and get a real transaction. Put the whole transactional unit inside
one `sync_to_async`-wrapped function instead of trying to hold the transaction open across
awaits.

### Client reuse under Django

backend-performance's HTTP/DB client-reuse rule applies here too — the Django mechanism is
a module-level `requests.Session()` (or `httpx.Client()`) created once at import, not a new
session per view call. Django has no `lifespan` hook; module scope, or `AppConfig.ready()`
if it needs settings loaded, is the equivalent. See backend-performance § HTTP/DB client
reuse for the *what/why*.

## DRF serializers are the input-validation boundary

**Hard rule**: request data is validated by a serializer at the edge of the view, before
any business logic or ORM call sees it. The serializer plays the role Pydantic plays in
fastapi-architecture — the difference is that DRF won't do it for you, so an unvalidated
`request.data` read is a real and common violation rather than something the framework
prevents.

```python
# DON'T — raw request.data straight into business logic and the ORM.
# No type coercion, no required-field check, no bounds; a missing key is a
# KeyError 500 and a wrong type is whatever the DB does with it.
class OrderCreate(APIView):
    def post(self, request):
        order = Order.objects.create(
            quantity=request.data["quantity"],
            sku=request.data["sku"],
        )
        return Response({"id": order.id})

# DO — serializer validates, then logic runs on validated_data only
class OrderCreateSerializer(serializers.Serializer):
    sku = serializers.CharField(max_length=32)
    quantity = serializers.IntegerField(min_value=1, max_value=1000)

class OrderCreate(APIView):
    def post(self, request):
        serializer = OrderCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)   # -> 400 with field errors
        order = services.place_order(**serializer.validated_data)
        return Response(OrderPublic(order).data, status=201)
```

Rules that follow from this:

- **`is_valid(raise_exception=True)`**, not a bare `is_valid()` whose return value gets
  ignored — a discarded boolean means invalid data proceeds to the ORM.
- **Read `validated_data`, never `request.data`, after validating.** Reaching back to
  `request.data` for one extra field bypasses the boundary for that field.
- **Cross-field rules go in `validate()`**, single-field rules in
  `validate_<field>()` — not in the view. A rule enforced in the view is a rule that's
  missing when the same serializer is used by another view, a management command, or the
  admin.
- **`ModelSerializer` needs explicit `fields`.** `fields = "__all__"` makes every new
  model column writable by any client, including ones added long after the serializer was
  written.

```python
# DON'T — "__all__" means a future `is_staff`/`credit_limit` column is client-writable
class UserSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = "__all__"

# DO — explicit, and read-only where the client shouldn't write
class UserSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = ["id", "email", "display_name", "created_at"]
        read_only_fields = ["id", "created_at"]
```

Model-level validators (`validators=[...]`, `MaxValueValidator`) are a good second layer,
but not a substitute: `Model.full_clean()` isn't called by `Model.save()`, so a model
validator never runs on an ORM write unless something calls it explicitly. The serializer
is the boundary that actually executes.

See backend-security § Input validation for the cross-cutting version of this rule.

## N+1 prevention — `select_related` / `prefetch_related`

**Hard rule**: a loop or serializer that issues one query per row of an earlier result
(N+1) must eager-load the related data in the original queryset. This is the Django-specific
mechanism behind backend-performance § N+1 query prevention.

Django's lazy relationship loading is what makes this so easy to write by accident: the
attribute access `order.customer` looks free, and there's no `await` or explicit query at
the call site to notice in review.

| Use | For | Mechanism |
|---|---|---|
| `select_related("customer")` | `ForeignKey`, `OneToOneField` (to-one) | SQL `JOIN`, same query |
| `prefetch_related("items")` | Reverse FK, `ManyToManyField` (to-many) | One extra query, joined in Python |

```python
# DON'T — 1 query for orders, then one more per order for its customer,
# and one more per order for its items: 1 + 2N round trips
for order in Order.objects.all():
    print(order.customer.name)          # query per row
    print(order.items.count())          # query per row

# DO — 2 queries total regardless of how many orders come back
orders = Order.objects.select_related("customer").prefetch_related("items")
for order in orders:
    print(order.customer.name)
    print(len(order.items.all()))       # already prefetched — no new query
```

`.count()` on a prefetched relation still hits the database — it issues its own `SELECT
COUNT(*)` and ignores the prefetch cache. Use `len(order.items.all())` when the rows are
already loaded, or annotate the count in the query:

```python
from django.db.models import Count

orders = Order.objects.annotate(item_count=Count("items"))
```

Nested and filtered prefetches use `Prefetch`:

```python
from django.db.models import Prefetch

orders = Order.objects.prefetch_related(
    Prefetch("items", queryset=Item.objects.filter(active=True).select_related("product"))
)
```

### The DRF case

A `ModelSerializer` with a nested serializer field or a `SerializerMethodField` that
touches a relation produces exactly this N+1, once per row of the response — and the
queryset lives in the view, not the serializer, so the fix isn't where the problem is
visible.

```python
class OrderSerializer(serializers.ModelSerializer):
    customer = CustomerSerializer()          # to-one  -> select_related
    items = ItemSerializer(many=True)        # to-many -> prefetch_related

# DON'T — serializer triggers 2 extra queries per row in the page
class OrderViewSet(viewsets.ModelViewSet):
    queryset = Order.objects.all()
    serializer_class = OrderSerializer

# DO — eager-load in the view's queryset to match what the serializer reads
class OrderViewSet(viewsets.ModelViewSet):
    queryset = Order.objects.select_related("customer").prefetch_related("items")
    serializer_class = OrderSerializer
```

**How to verify rather than guess**: `len(connection.queries)` with `DEBUG=True` in a test,
`assertNumQueries` in a Django `TestCase`, or `django-debug-toolbar` locally. A query count
that scales with page size is the signature.

```python
def test_order_list_query_count(self):
    OrderFactory.create_batch(20)
    with self.assertNumQueries(3):          # constant, not 1 + 2*20
        self.client.get("/api/orders/")
```

`assertNumQueries` is the cheapest regression guard for this — a later serializer change
that reintroduces the N+1 fails the test instead of shipping.

## Response shaping — serializer `fields` discipline

**Hard rule**: a response serializes only the fields its contract defines. This is the
Django-specific mechanism behind backend-performance § Response/payload shaping; in Django
the projection happens in the serializer's `Meta.fields`.

```python
# DON'T — every column on the model goes out, including whatever gets added later
class UserSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = "__all__"      # password (hash), is_superuser, internal flags, ...

# DON'T — model_to_dict / raw .values() with no projection is the same leak
def user_detail(request, pk):
    return JsonResponse(model_to_dict(User.objects.get(pk=pk)))

# DO — an explicit read serializer per response contract
class UserPublicSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = ["id", "email", "display_name"]
```

`exclude = [...]` is the weaker form of the same idea and fails in the direction that
matters: a column added to the model later is included by default, so the leak arrives with
a migration nobody connected to the API surface. Prefer `fields`.

Two related points:

- **Separate read and write serializers** when the shapes genuinely differ. One serializer
  doing both often ends up either accepting fields it shouldn't or returning fields it
  shouldn't, because `read_only_fields` is doing all the work.
- **Push the projection into the query too** — `.only("id", "email", "display_name")` or
  `.values(...)` so the database isn't sending columns the response drops. Serializer
  projection alone still fetches every column.

## Django-specific security

backend-security owns the cross-cutting rules and this section does not repeat them: CORS
allowlists, rate limiting, secrets management, security headers, and error-response shape
all live there. Read that skill for those. What follows is only what's specific to Django.

### CSRF protection

CSRF has no FastAPI equivalent — a stateless bearer-token API isn't vulnerable to it,
because the browser doesn't attach the token automatically. Django's default session
authentication **is** cookie-based, so it is, and `CsrfViewMiddleware` is the defense.

**Hard rule**: `django.middleware.csrf.CsrfViewMiddleware` stays in `MIDDLEWARE`, and
`@csrf_exempt` on a state-changing view is a violation unless the view is provably not
cookie-authenticated.

```python
# DON'T — silences the protection to make something work, with no reasoning
@csrf_exempt
def transfer_funds(request):
    ...

# DO — if it's a token-authenticated API endpoint, say so and let the
# authentication class carry it: DRF's TokenAuthentication/JWT are CSRF-exempt
# by design because they don't read credentials from cookies
class TransferFunds(APIView):
    authentication_classes = [JWTAuthentication]
    permission_classes = [IsAuthenticated]
```

DRF specifics worth knowing:

- `SessionAuthentication` enforces CSRF itself on unsafe methods — so a DRF view using
  sessions is covered even though DRF views are `csrf_exempt` at the Django level.
- A mixed `DEFAULT_AUTHENTICATION_CLASSES = [SessionAuthentication,
  TokenAuthentication]` means some requests to the same endpoint are cookie-authenticated
  and therefore CSRF-relevant. Don't reason about the endpoint as if it were token-only.
- `CSRF_TRUSTED_ORIGINS` must be an explicit list of origins, and needs the scheme
  (`https://app.example.com`) on Django ≥ 4.0.
- `CSRF_COOKIE_SECURE = True` and `SESSION_COOKIE_SECURE = True` in production, so neither
  cookie is transmitted over plaintext HTTP.

### `SECRET_KEY`

**Hard rule**: `SECRET_KEY` is read from the environment, with no fallback default in the
source. It signs sessions, password-reset tokens, and CSRF tokens — a known value means
forgeable sessions and password resets, not just a weak hash.

```python
# DON'T — the literal is in git history forever, and the `or` form is worse
# than no default: it silently works in production with a public key
SECRET_KEY = "django-insecure-8f3k2..."
SECRET_KEY = os.environ.get("SECRET_KEY", "dev-fallback")

# DO — absent env var fails loudly at startup, before serving a request
SECRET_KEY = os.environ["SECRET_KEY"]
```

The `django-insecure-` prefix `startproject` generates is a marker that the key is the
scaffolded one; finding it in a settings file that's deployed is a violation on its own.
See backend-security § Secrets management for the general rule.

### `DEBUG` and production settings

**Hard rule**: `DEBUG = False` in production, sourced from the environment. `DEBUG = True`
turns Django's error page into a full traceback with local variables, settings, and
fragments of SQL — handed to whoever triggered the error. It also makes
`django.db.connection.queries` accumulate every query for the process's lifetime, which is
a memory leak in a long-running worker.

```python
# DON'T
DEBUG = True
ALLOWED_HOSTS = ["*"]

# DO
DEBUG = os.environ.get("DJANGO_DEBUG", "false").lower() == "true"
ALLOWED_HOSTS = os.environ["DJANGO_ALLOWED_HOSTS"].split(",")
```

`ALLOWED_HOSTS = ["*"]` disables the `Host`-header check, which is what protects against
cache-poisoning and password-reset links pointing at an attacker's domain. Enumerate hosts.

**Use `python manage.py check --deploy`** — it's Django's own audit of exactly these
settings (`SECURE_HSTS_SECONDS`, `SECURE_SSL_REDIRECT`, `SESSION_COOKIE_SECURE`,
`CSRF_COOKIE_SECURE`, `DEBUG`, `SECRET_KEY` strength). Running it in CI against the
production settings module is a cheaper guard than reviewing settings by hand:

```shell
DJANGO_SETTINGS_MODULE=config.settings.prod python manage.py check --deploy --fail-level WARNING
```

The `SECURE_*` settings it checks implement backend-security § Security headers — Django
ships the middleware, so it's configuration rather than code here.

## Migrations

Django's migration state is a shared, ordered history that other environments and other
developers have already applied. That makes some edits safe and some destructive, and the
difference isn't visible in the diff.

**Hard rule: never edit a migration that has already been applied anywhere.** Applied
migrations are recorded by name in `django_migrations`; Django doesn't re-run or re-check
one it has already recorded. Editing it means the file and the actual database schema
diverge silently — every environment that already ran it keeps the old schema, every fresh
environment gets the new one, and nothing reports the split.

```shell
# DO — correct a mistake with a new migration on top
python manage.py makemigrations orders

# Only safe before the migration has been applied or shared:
python manage.py migrate orders 0004      # roll back to the previous one
# then delete/edit 0005 and regenerate
```

**Hard rule: models and migrations stay in sync.** A model field change with no
accompanying migration works locally against an already-correct dev database and fails on
the next fresh deploy. `makemigrations --check --dry-run` is the CI guard:

```shell
python manage.py makemigrations --check --dry-run   # non-zero exit if anything is missing
```

Other discipline:

- **Review generated migrations before committing.** `makemigrations` guesses on renames
  and can generate a drop-and-create where a `RenameField` was meant — which is data loss,
  from a command that looks purely mechanical.
- **Don't squash or delete migration files to tidy up.** Use `squashmigrations`, which
  leaves the replaced migrations in place with a `replaces` declaration so environments
  mid-history can still get there.
- **Separate schema changes from data migrations** where the data migration is slow. A
  `RunPython` in the same migration as an `AddField` holds the schema lock for the whole
  data pass.
- **Data migrations need `reverse_code`**, even if it's `migrations.RunPython.noop` — a
  migration with no reverse blocks rollback of everything after it.
- **Adding a non-nullable column to a populated table needs three steps**: add it nullable
  (or with a default), backfill, then alter to non-null. One-step `AddField(null=False)`
  with no default fails on any table with rows.

```python
# DO — a data migration with an explicit no-op reverse
def backfill_slug(apps, schema_editor):
    Order = apps.get_model("orders", "Order")   # historical model, not the import
    for order in Order.objects.filter(slug="").iterator():
        order.slug = slugify(order.reference)
        order.save(update_fields=["slug"])

class Migration(migrations.Migration):
    dependencies = [("orders", "0004_add_slug")]
    operations = [migrations.RunPython(backfill_slug, migrations.RunPython.noop)]
```

Use `apps.get_model()` inside a data migration, never a direct model import. The imported
model is today's model; the migration has to run against the schema as it was at that point
in history, which is what `apps.get_model` gives you.

## Anti-patterns

### Hard rules — always flag as violations

Correctness and reliability bugs. Flag these regardless of the project's age or existing
conventions — see [Scope](#scope).

| Anti-pattern | Why it's wrong | Fix |
|---|---|---|
| Sync ORM call (`Model.objects.get(...)`, queryset evaluation) inside an `async def` view | Blocks the event loop for the query's duration; usually raises `SynchronousOnlyOperation`, but a lazy `QuerySet` can escape the view and evaluate elsewhere. | Async ORM methods (`aget`, `acreate`, `async for`), or `sync_to_async(..., thread_sensitive=True)`. |
| `transaction.atomic()` wrapping `await`ed work in an async view | `atomic()` is thread-local and sync-only — there's no real transaction around the awaited calls. | Put the whole transactional unit in one `sync_to_async`-wrapped function. |
| `request.data` read into business logic or the ORM with no serializer | No type coercion, no required-field check, no bounds; missing key is a 500, wrong type is whatever the DB does with it. | Validate with a serializer, `is_valid(raise_exception=True)`, then use `validated_data` only. |
| `serializer.is_valid()` whose return value is ignored | Invalid data proceeds to the ORM as if it had passed. | `is_valid(raise_exception=True)`. |
| `ModelSerializer` with `fields = "__all__"` (or `exclude`) on a write path | Every current and future model column becomes client-writable — including one added by a later migration. | Explicit `fields = [...]` plus `read_only_fields`. |
| Response returning a full model row: `fields = "__all__"`, `model_to_dict`, unprojected `.values()` | Serializes fields the contract never promised — password hashes, internal flags, other relations. | Read serializer with explicit `fields`; project in the query with `.only()`/`.values()` too. |
| Relation accessed per row of a queryset (`order.customer`, `order.items.all()`) with no eager loading | N+1: 1 request becomes 1+N round trips, scaling with result size. | `select_related` (to-one) / `prefetch_related` (to-many) on the queryset. |
| DRF nested serializer or `SerializerMethodField` touching a relation, with a bare `queryset = Model.objects.all()` | Same N+1, once per row of the page; the fix is in the view while the symptom is in the serializer. | Eager-load in the view's `queryset`/`get_queryset()` to match what the serializer reads. |
| `.count()` on an already-prefetched relation | Ignores the prefetch cache and issues its own `SELECT COUNT(*)` per row. | `len(rel.all())` when prefetched, or `annotate(Count(...))`. |
| `DEBUG = True` (or defaulting to true) in deployed settings | Returns tracebacks with locals, settings and SQL to the client; `connection.queries` grows unbounded in the worker. | `DEBUG` from env, defaulting to false; verify with `manage.py check --deploy`. |
| `ALLOWED_HOSTS = ["*"]` | Disables the `Host`-header check that protects against cache poisoning and poisoned password-reset links. | Enumerate hosts explicitly, from env. |
| Hardcoded `SECRET_KEY`, or `os.environ.get("SECRET_KEY", "fallback")` | Signs sessions, CSRF and password-reset tokens — a known key means forgeable sessions and resets. The fallback form silently ships a public key. | `os.environ["SECRET_KEY"]` — fail at startup if absent. See backend-security § Secrets management. |
| `CsrfViewMiddleware` removed from `MIDDLEWARE` | Every cookie-authenticated state-changing endpoint becomes forgeable cross-site. | Keep the middleware; exempt individual token-authenticated views if genuinely needed. |
| `@csrf_exempt` on a state-changing view without establishing it isn't cookie-authenticated | Removes CSRF protection from a write path; often added to silence an error during development and never revisited. | Use a token/JWT authentication class (CSRF-exempt by design), or keep CSRF and send the token. |
| `CSRF_COOKIE_SECURE`/`SESSION_COOKIE_SECURE` left false in production | Session and CSRF cookies transmitted over plaintext HTTP. | Set both true; `manage.py check --deploy` flags them. |
| Editing a migration that has already been applied | `django_migrations` records it as done, so it never re-runs — file and actual schema diverge silently across environments. | Add a new migration on top. |
| Model field change committed with no corresponding migration | Works against an already-correct dev DB, fails on the next fresh deploy. | `makemigrations`; guard with `makemigrations --check --dry-run` in CI. |
| Direct model import inside a data migration instead of `apps.get_model()` | Runs today's model against a historical schema; breaks as soon as the model moves on. | `apps.get_model("app", "Model")`. |
| `RunPython` with no `reverse_code` | Blocks rollback of that migration and everything after it. | Pass a reverse function, or `migrations.RunPython.noop`. |
| `AddField(null=False)` with no default on a populated table | Fails outright on any table with existing rows. | Add nullable → backfill → alter to non-null, as three migrations. |
| Business logic in the view body (ORM writes, branching, external calls) | Unreachable from management commands, tasks, and the admin; forces HTTP-level tests for domain rules. | Move to a model method/manager or a service function — see [structure](#project-structure--one-app-per-bounded-domain-structural-preference--advisory). |
| One app reaching directly into another app's models for queries/behavior | Couples the apps at schema level; a change to one app's internals breaks the other silently. | Call the owning app's public surface. `ForeignKey` across apps is fine. |
| `requests.Session()`/`httpx.Client()` constructed per view call | New connection pool and TCP/TLS setup on every request. | Module-level client, or `AppConfig.ready()`. See backend-performance § HTTP/DB client reuse. |
| Deployed with `manage.py runserver` | Single-threaded dev server, no process supervision, explicitly not for production. | Gunicorn/uWSGI (WSGI) or Uvicorn/Daphne (ASGI) behind a process manager. |

### Structural preferences — advisory, respect existing convention

These follow from the [one-app-per-bounded-domain](#project-structure--one-app-per-bounded-domain-structural-preference--advisory)
recommendation above. Don't flag them as violations in a project with an established,
different convention — note them only if asked to audit structure specifically, framed as
"this project organizes apps by X" rather than an error.

| Pattern | One-app-per-domain rationale | If the project uses a different convention |
|---|---|---|
| One app holding every model in the project | All domains share one migration timeline; splitting later needs state operations, not a file move | Note it as "this project uses a single app for all domains" — not a violation in an established codebase |
| Apps split by technical layer (`api/`, `models/`, `services/`) rather than by domain | Everything about one feature is scattered across apps; app-scoped migrations no longer track a domain | Note it as "this project organizes apps by layer" — not a violation under an established layered convention |
| No `services.py`, with domain logic on models/managers instead | Neither is preferred — "fat models, thin views" is an equally valid Django convention | Not a finding at all. Only logic living *in the view* is a hard rule |
| Single `settings.py` rather than a `settings/` package split by environment | One file per environment makes prod-only settings (`DEBUG`, hosts, cookie flags) explicit rather than conditional | Note it as "this project uses a single settings module with env conditionals" — not a violation |
