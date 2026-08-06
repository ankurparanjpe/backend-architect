# Contributing

## The split every skill keeps: hard rule vs structural preference

Every contribution starts by deciding which of the two kinds of rule you're writing, because
they land in different sections and are enforced differently. The test is one question: **is
this wrong in every project, or only in a project that doesn't already do it another way?**

| | Hard rule | Structural preference |
|---|---|---|
| What it is | A correctness or reliability bug — exploitable, data-losing, or outage-causing | An organizational recommendation — layout, naming, which library |
| How it's reported | `VIOLATION:` regardless of the project's age or conventions | An advisory note, and only when a structure audit was asked for |
| Where it lives | `### Hard rules — always flag as violations` | `### Structural preferences — advisory, respect existing convention`, plus an inline advisory blockquote on the prose section |
| Examples | `requests.get()` inside `async def` (blocks the loop); wildcard CORS with `allow_credentials`; a cache key with no user scope; an unpaginated list endpoint; a retry around a non-idempotent `POST` with no idempotency key | Domain-based vs layered folders; Flask's `create_app()` factory vs a module-level app; which circuit-breaker library; the specific backoff numbers; Marshmallow vs Pydantic |

Two failure modes to avoid, both of which get the plugin uninstalled:

- **A preference filed as a hard rule.** It flags established codebases for having made a
  different reasonable choice. Flask's application factory was exactly this and was
  downgraded in `0.1.16` — testability is a real benefit, but a small single-config service
  with a module-level app isn't broken.
- **A bug filed as a preference.** It gets silently skipped on any project with a convention,
  which is every project. If the failure mode is an outage or a data leak, it's a hard rule
  even when it looks like layout.

When a topic has both halves — a principle that survives stripping the framework syntax, plus
the syntax itself — split it across two skills rather than picking one. See
[Proposing a new skill](#proposing-a-new-skill).

## Adding a hard rule to an existing skill

A hard rule is a correctness or reliability bug — something exploitable, data-losing, or
outage-causing — not a style preference. If it depends on the project's conventions, it's a
structural preference, and it belongs in that section instead.

1. **Add the row to the skill's anti-pattern table** under
   `### Hard rules — always flag as violations`. Keep the three-column shape:
   anti-pattern / why it's wrong / fix. The "why" has to name the actual failure, not restate
   the rule — "blocks the event loop" beats "is not async". If the rule needs more than a
   table row to explain, add a prose section above and keep the table row as the short form.
2. **Add a matching violation to the skill's fixture** in
   `tests/fixtures/<skill-name>/`. One planted violation per rule, so a regression is
   attributable to a single row. Keep the fixture realistic — code a reviewer would plausibly
   see, not a labelled minimal repro.
3. **Run the fixture check locally and confirm it still triggers.** This step is on you —
   **CI does not run it** (see [What CI checks](#what-ci-checks) below). Run
   `tests/fixtures/<skill-name>/check.sh` with your own Claude Code install and API access —
   the script shells out to `claude -p`, so it needs both — and verify that your new rule
   appears in the output as a `VIOLATION:` line *and* that every `VIOLATION:` line that was
   already expected still fires. The script exits non-zero and prints
   `MISSING expected violation: ...` when one stops firing; a clean run ends in
   `OK: all expected hard-rule violations detected`.

   A new table row that shadows or dilutes an existing one is the common failure mode here,
   and this check is the only thing that catches it. If your change touches the shared
   hard-rule surface, also run `tests/fixtures/audit-architecture/check.sh`, which verifies
   the `/audit-architecture` command still attributes each violation to the right skill.
4. **Bump `version` in `.claude-plugin/plugin.json`** (patch level minimum) and keep
   `.claude-plugin/marketplace.json`'s version in sync — they're two copies of the same
   number. `tests/check_version_bump.sh` verifies both locally, against the same base-branch
   comparison CI uses.
5. **Open the PR with the `check.sh` output pasted into the description**, and make sure it
   passes CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)).

## What CI checks

CI is deliberately narrow. It runs three checks on every push and pull request, all of which
work with nothing but the repo itself:

- **Structural assertions** (`tests/check_skill_structure.sh`) — hard fail, runs first.
  Structural assertions run automatically in CI; they verify every skill has the required
  sections and a paired fixture. Concretely: every `skills/*/` directory has a `SKILL.md`,
  every `SKILL.md` has a `## Scope` section and a `## Anti-patterns` section with at least
  one table entry, every skill has a `tests/fixtures/<skill>/bad_*.py` fixture carrying the
  `Intentional test fixture` docstring marker, and `plugin.json`'s version is valid semver.
  It's a shape check, not a quality check — it says nothing about whether the rules fire.
- **Manifests and version bump** (`tests/check_version_bump.sh`) — hard fail. Validates that
  `plugin.json` and `marketplace.json` are well-formed and carry the same version, and that
  if any `skills/*/SKILL.md` or `commands/*.md` changed relative to the base branch, the
  version was actually bumped.
- **Skill description overlap** (`python3 tests/check_descriptions.py`) — warning only, does
  not fail the build. Flags trigger wording claimed by more than one skill, and descriptions
  missing negative scope or a sibling pointer.

**CI does not verify fixture correctness.** Nothing in the workflow runs
`tests/fixtures/*/check.sh`. Those scripts invoke `claude -p`, so they need an API key and
they grade model output, which makes them a poor fit for automation in a plugin repo — and
this repo has no key configured, by choice. So a green CI badge means *the structure, the
manifests, and the version bump are fine*, and nothing more. It does not mean your rule
still fires.

**Fixture correctness is verified by the contributor, not by CI.** Step 3 above is the real
regression test for skill content, and running it is a condition of opening the PR, not an
optional extra. Paste the output into the PR description. Reviewers may ask for fixture
output — or for a re-run — whenever a change to a hard-rule table makes it doubtful that the
existing rules still fire.

## Proposing a new skill

If the area you have in mind is already a known gap — WebSocket, GraphQL, or gRPC
architecture, containerization, messaging, multi-tenancy, API versioning, supply-chain
security — [`ROADMAP.md`](ROADMAP.md) describes what a skill covering it would have to
include and why it isn't here yet. Start with an issue naming which one you're taking, so
two people don't build the same skill. For an area not on that list, the issue should make
the case that it's skill-sized and not already covered by a section of an existing skill.

### Step 1: cross-cutting or framework-specific?

The first decision is cross-cutting vs framework-specific, and it's not "which one feels
bigger" — it's about where the content stops being true.

**Cross-cutting** if the principle holds with no framework named at all. Pagination on list
endpoints, client reuse, cache key scoping, log redaction — all true for FastAPI, Django,
Flask, Express, and a bare WSGI app.

**Framework-specific** if the content is syntax, API surface, or wiring that only exists in
one framework. `selectinload` vs `joinedload`, `Annotated[..., Depends(...)]`, Django's
`SECURE_*` settings.

**Most real topics are both** — and then the answer is to split, not to pick.
`backend-performance` is the worked example. The topic looked FastAPI-shaped at first: pool
sizing meant SQLAlchemy's `pool_size`/`max_overflow`, N+1 meant `selectinload`, payload
shaping meant `response_model`. But strip the syntax and every rule survives: *size your pool
deliberately against worker count and the DB's connection limit*, *don't issue one query per
row*, *serialize only the fields the contract defines*. So the principle and the hard rule
live in `backend-performance`, the mechanism and syntax live in `fastapi-architecture`, and
each side carries an explicit pointer to the other (see `backend-performance` §Connection
pool sizing → "see fastapi-architecture § Database"). The pointers are the point — they're
what keeps the two halves from drifting apart as either side is edited.

If the principle doesn't survive stripping the syntax, it was framework-specific all along.

### Step 2: write the `description` field first

Skill selection is driven **entirely** by these descriptions, so two skills claiming the same
trigger terms makes the choice between them ambiguous — and an ambiguous trigger means the
wrong skill loads, or both do. Before adding trigger terms, read every existing skill's
`description` and pick wording none of them claim. Then state the boundary explicitly, the way
the current skills do: name the sibling skills your topic is adjacent to and what belongs to
them ("does not cover caching (see backend-caching)"). Negative scope is as load-bearing as
positive.

`python3 tests/check_descriptions.py` flags overlapping trigger wording and descriptions
missing negative scope. It's warning-only, so read the output rather than relying on the exit
code.

### Step 3: write `skills/<skill-name>/SKILL.md`

Keep the hard rule vs structural preference split explicit. Every skill needs a `## Scope`
section stating it, and structural-preference sections need the inline advisory blockquote
that points back to it. Use
[`skills/fastapi-architecture/SKILL.md`](skills/fastapi-architecture/SKILL.md) §Scope as the
reference format — same two-bullet shape, same "don't flag deviations in an established
codebase" language. A skill without this split will fight existing projects and get disabled.

Close with an `## Anti-patterns` section carrying both tables: `### Hard rules — always flag
as violations` (three columns: anti-pattern / why it's wrong / fix) and `### Structural
preferences — advisory, respect existing convention`. `tests/check_skill_structure.sh` fails
the build if either the `## Scope` or the `## Anti-patterns` section is missing.

### Step 4: add the fixture and its `check.sh`

Under `tests/fixtures/<skill-name>/`, following the existing pattern: one `bad_*.py` with
deliberately planted violations — one per hard rule, so a regression is attributable to a
single row — and one `check.sh` that prompts against only that skill's hard-rule table and
expects each violation back. The fixture's module docstring must contain the string
`Intentional test fixture`; the structural check asserts it, and it's what stops someone
"fixing" the file.

Where you've deliberately downgraded a rule to advisory, add a negative assertion too — see
`tests/fixtures/flask-architecture/check.sh`, which fails if the module-level `Flask()`
instance is ever reported as a hard-rule violation again.

### Step 5: register it everywhere it has to appear

- **`/audit-architecture`.** A new cross-cutting skill has to be added to the dispatch list in
  [`commands/audit-architecture.md`](commands/audit-architecture.md) §4 *and* to
  `tests/fixtures/audit-architecture/check.sh` (its fixture in the input list, its expected
  violations as `check_in` lines). A skill that isn't in both is invisible to the command, and
  nothing else catches that. This matters most when the new skill's rule pairs with an
  existing framework-skill rule — the audit check is what verifies each violation is still
  attributed to the intended skill rather than drifting to its cross-referenced twin.
- **A row in the README's [What's included](README.md#whats-included) table**, in the
  framework or cross-cutting group as appropriate.
- **[`ROADMAP.md`](ROADMAP.md)** — move the area out of "Intentional gaps" into "Current
  coverage".
- **A version bump** in both manifests (see step 4 of
  [Adding a hard rule](#adding-a-hard-rule-to-an-existing-skill)).

### Step 6: run the checks

`tests/check_skill_structure.sh` and `tests/check_version_bump.sh` locally (both are what CI
runs), plus your new `tests/fixtures/<skill-name>/check.sh` and
`tests/fixtures/audit-architecture/check.sh`. Paste the fixture output into the PR.

## Why `/audit-architecture` is a command, not a hook

The plugin ships no lifecycle hooks, and contributions don't need to add any. Everything here
is opt-in: skills load when a request matches their trigger wording, and `/audit-architecture`
runs when you invoke it. Nothing fires on save, on commit, or on a timer.

That's deliberate. An architecture review is a judgment call over a diff, and a rule set this
opinionated produces advisory notes as well as violations — running it unprompted on every
save would either block work on style disagreements or train everyone to ignore its output.
The hard rules are also cheap to catch closer to the source where that's possible: ruff's
`ASYNC` ruleset covers part of the FastAPI blocking-call rule at lint time, which is a better
place for it than a model call (see `fastapi-architecture` § Linting).

If a team wants this on every commit, that's a pre-commit hook wrapping `claude -p` in their
own repo — a local policy decision, not something the plugin should impose on everyone who
installs it.
