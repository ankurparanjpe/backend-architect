#!/usr/bin/env python3
"""Flag ambiguous or overlapping trigger wording across skills' SKILL.md descriptions.

Skill selection is driven entirely by the `description` field, so two skills
claiming the same trigger terms makes the choice between them ambiguous. This
mechanises the three criteria CONTRIBUTING.md states under "What any new skill
has to keep":

  1. no two skills claim the same trigger terms
  2. every description states negative scope ("does not cover ...", "do not use for ...")
  3. that negative scope names the sibling skills it borders

Only the POSITIVE half of each description is compared - the negative half names
sibling topics on purpose, so counting it would report nothing but noise.

Warnings only: prints ::warning:: lines and always exits 0.
"""
import re
import sys
from collections import defaultdict
from pathlib import Path

SKILLS = Path(__file__).resolve().parent.parent / "skills"

# first marker that starts the deliberate "what this is NOT" half - includes the
# handoff phrasing ("... lives in the sibling framework skill"), which is negative
# scope written as a pointer rather than a denial
NEGATIVE = re.compile(
    r"(this skill does not cover|does not cover|do not use for|do not use"
    r"|liv(?:e|es) in the sibling|,\s*nor\b|\bnor\b)",
    re.I,
)
WORD = re.compile(r"[a-z][a-z0-9_./+]{3,}")
# generic English filler plus this plugin's conventional scaffolding wording
# (every description says "cross-cutting backend ... in any framework (FastAPI,
# Django, Flask, Express)") - shared by convention, so it carries no trigger signal
STOP = {
    "this", "that", "with", "when", "work", "works", "touches", "into", "from", "than",
    "them", "they", "their", "these", "those", "your", "have", "has", "been", "also",
    "only", "over", "other", "otherwise", "instead", "using", "used", "uses", "use",
    "e.g.", "i.e.", "etc.", "etc", "such", "like", "does", "not", "and", "for", "the",
    "any", "all", "all.", "one", "own", "per", "its", "clearly", "identifies", "carry",
    "here", "state", "states", "which", "what", "where", "some", "more", "most",
    "each", "both", "just", "will", "would", "should", "must", "made", "make", "makes",
    "backend", "framework", "frameworks", "fastapi", "django", "flask", "express",
    "cross", "cutting", "apply", "applies", "regardless", "rule", "rules", "skill",
    "skills", "sibling", "siblings", "plugin", "named", "specific",
}


def description(path: Path) -> str:
    """Pull the description value out of YAML frontmatter (no pyyaml dependency)."""
    lines = path.read_text().splitlines()
    if not lines or lines[0].strip() != "---":
        return ""
    out, inside = [], False
    for ln in lines[1:]:
        if ln.strip() == "---":
            break
        if re.match(r"^description\s*:", ln):
            inside = True
            out.append(re.sub(r"^description\s*:\s*[>|]?[-+]?\s*", "", ln))
            continue
        if inside:
            if not ln.strip() or ln.startswith((" ", "\t")):
                out.append(ln.strip())
            else:  # dedented back to a sibling key
                break
    return " ".join(p for p in out if p)


def terms(text: str) -> set[str]:
    """Distinctive words + bigrams from a description's positive half."""
    words = [w for w in WORD.findall(text.lower().replace("`", "")) if w not in STOP]
    return set(words) | {f"{a} {b}" for a, b in zip(words, words[1:])}


def main() -> int:
    skills = {}
    for skill_md in sorted(SKILLS.glob("*/SKILL.md")):
        name = skill_md.parent.name
        desc = description(skill_md)
        if not desc:
            print(f"::warning file={skill_md}::no description field found in frontmatter")
            continue
        m = NEGATIVE.search(desc)
        skills[name] = {
            "file": skill_md,
            "positive": desc[: m.start()] if m else desc,
            "negative": desc[m.start():] if m else "",
        }

    warnings = 0

    # 1. trigger terms claimed by more than one skill
    claims = defaultdict(list)
    for name, s in skills.items():
        for t in terms(s["positive"]):
            claims[t].append(name)
    # a term every skill uses is structural boilerplate ("backend", "framework"),
    # not a contested trigger - only partial overlap is ambiguous
    shared = {
        t: owners
        for t, owners in claims.items()
        if 1 < len(owners) < len(skills)
    }
    by_pair = defaultdict(list)
    for t, owners in shared.items():
        by_pair[tuple(sorted(owners))].append(t)
    for owners, ts in sorted(by_pair.items(), key=lambda kv: -len(kv[1])):
        # single shared word between two skills is normal; a cluster is the smell
        if len(ts) < 3:
            continue
        warnings += 1
        print(
            f"::warning::overlapping trigger wording in {', '.join(owners)}: "
            f"{', '.join(sorted(ts)[:12])} - state the boundary explicitly or reword"
        )

    # 2 + 3. negative scope present, and it names siblings
    for name, s in skills.items():
        if not s["negative"]:
            warnings += 1
            print(
                f"::warning file={s['file']}::{name}: description states no negative scope "
                f'- add a "does not cover ... (see <sibling>)" clause'
            )
            continue
        neg = s["negative"].lower()
        if not any(other.lower() in neg for other in skills if other != name):
            warnings += 1
            print(
                f"::warning file={s['file']}::{name}: negative scope names no sibling skill "
                f"- say which skill owns the adjacent topic"
            )

    print(f"description check: {len(skills)} skills, {warnings} warning(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
