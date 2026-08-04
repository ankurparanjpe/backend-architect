# Contributing

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
3. **Confirm the fixture still triggers**: run `tests/fixtures/<skill-name>/check.sh` and
   verify your new rule appears in the output *and* that the rules that were already there
   still do. A new table row that shadows or dilutes an existing one is the common failure
   mode here — the check is what catches it.
4. **Bump `version` in `.claude-plugin/plugin.json`** (patch level minimum) and keep
   `.claude-plugin/marketplace.json`'s version in sync — they're two copies of the same
   number.
5. Open the PR with the check output in the description.

## Proposing a new skill

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

### What any new skill has to keep

- **The hard rule vs structural preference split.** Every skill needs a `## Scope` section
  making it explicit, and structural-preference sections need the inline advisory note that
  points back to it. Use
  [`skills/fastapi-architecture/SKILL.md`](skills/fastapi-architecture/SKILL.md) §Scope as the
  reference format — same two-bullet shape, same "don't flag deviations in an established
  codebase" language. A skill without this split will fight existing projects and get
  disabled.
- **Non-overlapping trigger wording in the `description` field.** Skill selection is driven
  entirely by these descriptions, so two skills claiming the same trigger terms makes the
  choice between them ambiguous — and an ambiguous trigger means the wrong skill loads, or
  both do. Before adding trigger terms, read every existing skill's `description` and pick
  wording none of them claim. Then state the boundary explicitly, the way the current skills
  do: name the sibling skills your topic is adjacent to and what belongs to them ("does not
  cover caching (see backend-caching)"). Negative scope is as load-bearing as positive.
- **A fixture and a `check.sh`** under `tests/fixtures/<skill-name>/`, following the existing
  pattern: one file with deliberately planted violations, one script that prompts against
  only that skill's hard-rule table and expects each violation back.
- **A row in the README's "What's included" table**, plus a version bump.
