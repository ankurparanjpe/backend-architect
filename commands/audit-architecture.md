---
description: Audit a file, path, or the current diff against the matching framework skill plus all applicable cross-cutting backend skills, grouped by skill.
argument-hint: [path] [--framework=fastapi|django|flask] [--skip=skill-name,...]
allowed-tools: Bash, Read, Grep, Glob, Task
---

# Audit Architecture

Raw arguments: `$ARGUMENTS`

## 1. Parse arguments

From `$ARGUMENTS`, extract:
- `--framework=<fastapi|django|flask>` if present — overrides auto-detection in step 3.
- `--skip=<comma-separated skill names>` if present (e.g. `backend-caching,backend-performance`)
  — these skills are excluded from dispatch entirely and listed as "skipped by request" in
  the final summary.
- Whatever remains after stripping the two flags above is the **target**: a file path, a
  directory path, or empty.

## 2. Resolve the target content

- If the remaining argument is a file or directory path that exists, read it directly
  (`Read`, or `Grep`/`Glob` first if it's a directory).
- If no path was given, use the diff instead: run `git diff --staged`; if that's empty, run
  `git diff`. If both are empty, stop and tell the user there's nothing to audit (no path
  given, no staged or unstaged changes).

## 3. Detect the framework (skip this step entirely if `--framework=` was passed)

Search the target content — and, if a path was given, sibling files in the same project
root — for these signals, in this priority order, stopping at the first match:

1. **Django** — `manage.py` at the project root alongside a `settings.py`, or `django.`
   imports.
2. **Flask** — `from flask import Flask` / `Flask(__name__)`.
3. **FastAPI** — `from fastapi import FastAPI`, `FastAPI()`, or `APIRouter` usage.

If none match, report "no framework detected — running cross-cutting skills only" and
proceed without a framework skill.

If a framework is detected but `skills/<framework>-architecture/SKILL.md` doesn't exist yet
(currently true for Django and Flask — only `fastapi-architecture` is implemented), say so
explicitly, e.g. "Framework detected: Django, but django-architecture isn't implemented
yet — skipping framework-specific check," and proceed with the cross-cutting skills only.

## 4. Build the skill dispatch list

Start with:
- the detected/overridden framework skill, if its `SKILL.md` exists
- `backend-security`, `backend-observability`, `backend-caching`, `backend-performance`

Remove any skill named in `--skip=`.

## 5. Dispatch one focused check per skill

For each skill remaining in the list, spawn a separate `Task` subagent — send all of them in
one message so they run in parallel. Isolating each skill in its own subagent keeps one
skill's rules from bleeding into another's review. Give each subagent:

- The skill's own content (point it at `skills/<skill-name>/SKILL.md`) and nothing else.
- The target content from step 2.
- This exact instruction:

  > First check this skill's own "Use when… / Do not use for…" scope against the target. If
  > the target doesn't touch this skill's concern, output exactly
  > `NOT APPLICABLE: <one-line reason>` and stop — nothing else.
  >
  > Otherwise, using ONLY this skill's "Hard rules — always flag as violations" table,
  > output one line per violation as `VIOLATION: <short rule name>`. If none, output `NONE`.
  >
  > Then, using ONLY this skill's "Structural preferences" section, output one line per
  > advisory note as `PREF: <short note>`. If none, output `NONE`.
  >
  > Output nothing else: no fixes, no prose, no restated code.

## 6. Aggregate and present, grouped by skill

Render the combined result in this shape, in dispatch order (framework skill first, then
security, observability, caching, performance):

```
# Architecture Audit — <target description>

Framework: <detected/overridden framework, or "none detected">
Skipped: <comma list from --skip, or "none">

## <skill-name>
NOT APPLICABLE: <reason>
```

or, for an applicable skill:

```
## <skill-name>
Hard rule violations:
- VIOLATION: <rule>
(or "None found")

Structural preferences (advisory):
- PREF: <note>
(or "None noted")
```

End with a one-line summary: total hard-rule violation count across all applicable skills,
plus how many skills were not applicable or skipped.
