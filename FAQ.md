# FAQ

### Do I need to run the plugin on every commit?

No. There's nothing to run on a schedule and no hook to install. The skills are opt-in two
ways: they load automatically when what you're asking about matches a skill's trigger
wording ("review this router for anything that'll break in production"), or you invoke
`/audit-architecture` for a deliberate, grouped pass. Between those, the plugin is inert.

If you *want* it on every commit, that's a pre-commit hook you write, not something the
plugin ships — see [`CONTRIBUTING.md`](CONTRIBUTING.md#why-audit-architecture-is-a-command-not-a-hook)
for why that's deliberate.

### Does it work with monorepos?

Yes. `/audit-architecture` detects the framework from the target's content and its sibling
files, so pointing it at one service in a monorepo audits that service:

```
/audit-architecture services/orders/
```

If a path is ambiguous — several frameworks in one tree, or a shared library with no
framework signal at all — pass `--framework=` explicitly:

```
/audit-architecture libs/shared/ --framework=fastapi
```

With no framework signal and no override, the command says so and runs the cross-cutting
skills only, which is the correct result for framework-agnostic code.

### Can I use this with my own team's rules?

Yes. Your own skills sit alongside these, and a project-level skill in `.claude/skills/` (or
a `CLAUDE.md` rule) is the right home for a house convention that contradicts one of them.
Two things make it land cleanly:

- Give your skill trigger wording these nine don't claim, and state the override explicitly
  in its description ("supersedes backend-caching § Key design for our Redis conventions").
  Skill selection is driven entirely by descriptions, so an explicit boundary is what keeps
  yours from competing with a plugin skill instead of replacing it.
- Use `--skip=` to drop a plugin skill from an audit run where your own rules own the topic:
  `/audit-architecture src/ --skip=backend-caching`.

### What if my project doesn't follow these rules yet?

Start with the hard rules and ignore the rest. Every skill splits its content in two, and
the split exists specifically so the plugin doesn't fight an established codebase:

- **Hard rules** are correctness and reliability bugs — a blocking call in `async def`,
  wildcard CORS with credentials, a secret in source, an unpaginated list endpoint. These
  get flagged regardless of your project's age or conventions, because they're bugs.
- **Structural preferences** are advisory notes, never violations. Domain-based vs layered
  folders, Blueprint-per-domain, the Flask application factory. If your project already
  has a different convention, the skill notes "this project uses X instead" — and only
  when you explicitly ask for a structure audit.

So an audit of an old codebase should produce a short hard-rule list and little else. If
it reads like a migration plan, something is miscategorized — that's a bug worth filing.

### Can you add WebSocket/GraphQL coverage?

Not yet, and the gap is deliberate rather than overlooked — see
[`ROADMAP.md`](ROADMAP.md#protocol-specific-skills-future) for what a WebSocket, GraphQL, or
gRPC skill would have to cover. In the meantime, every cross-cutting skill states its
HTTP/REST protocol assumption in its `## Scope` section, and the places where a rule's
mechanism genuinely differs carry an in-place note instead of a guess (`backend-security`
§ Status codes carry the failure has both a GraphQL and a gRPC note).

If you want one of these built, an issue describing the specific gap is useful signal, and
[`CONTRIBUTING.md`](CONTRIBUTING.md#proposing-a-new-skill) has the process if you have
production expertise in that area.

### Why are there nine skills instead of one big one?

Because a skill only loads when its trigger wording matches, and one skill covering
everything would either load constantly or never. The split also isolates review passes:
`/audit-architecture` runs each skill in its own subagent so one skill's rules don't bleed
into another's findings, which is what makes the grouped output trustworthy.

### Does a green CI badge mean the rules still work?

No. CI runs structural and manifest checks only — see
[`CONTRIBUTING.md` § What CI checks](CONTRIBUTING.md#what-ci-checks). The checks that grade
whether a rule actually fires (`tests/fixtures/*/check.sh`) invoke `claude -p`, so they
need an API key and are a contributor responsibility, run locally and pasted into the PR.
