#!/usr/bin/env bash
# Structural assertions for the plugin's skills and fixtures. Pure text checks — no
# API key, no model calls, no network — so this runs in CI on every push and PR.
#
# It verifies *shape*, not rule quality: that every skill has the sections the Scope
# convention requires, both anti-pattern tables, and a paired fixture plus a runnable
# check.sh. Whether a skill's rules still fire is graded by tests/fixtures/*/check.sh
# itself, which needs `claude -p` and stays a local/contributor step — see
# CONTRIBUTING.md. Every requirement CONTRIBUTING documents for a new skill should be
# asserted here; a documented requirement nothing checks is a requirement that rots.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAIL=0
fail() { echo "FAIL: $*"; FAIL=1; }

# Count data rows in the markdown table under a given `### ` subsection heading.
# A data row is a |-row following a |---|---| separator, so the table's own header
# row isn't counted. Stops at the next heading of any level, which keeps the two
# Anti-patterns subsections (hard rules, structural preferences) from bleeding into
# each other. $1 = file, $2 = heading prefix to match from the start of the line.
table_entries() {
  awk -v want="$2" '
    index($0, want) == 1 { in_table = 1; after_sep = 0; next }
    in_table && /^#/ { exit }
    in_table && /^\|[-: |]+\|[[:space:]]*$/ { after_sep = 1; next }
    in_table && after_sep && /^\|/ { n++; next }
    in_table && !/^\|/ { after_sep = 0 }
    END { print n + 0 }
  ' "$1"
}

shopt -s nullglob

skill_dirs=(skills/*/)
if [ ${#skill_dirs[@]} -eq 0 ]; then
  fail "no skill directories found under skills/"
fi

for dir in "${skill_dirs[@]}"; do
  skill="$(basename "$dir")"
  md="${dir}SKILL.md"

  if [ ! -f "$md" ]; then
    fail "$skill: no SKILL.md"
    continue
  fi

  grep -q '^## Scope' "$md" || fail "$skill: SKILL.md has no '## Scope' section"

  if ! grep -q '^## Anti-patterns' "$md"; then
    fail "$skill: SKILL.md has no '## Anti-patterns' section"
  else
    # Both subsection tables are required, not just one of them — a skill with only
    # hard rules fights established codebases, and one with only preferences flags
    # nothing. CONTRIBUTING.md § Step 3 documents both; this is what enforces it.
    [ "$(table_entries "$md" '### Hard rules')" -ge 1 ] \
      || fail "$skill: no table entries under '### Hard rules' in '## Anti-patterns'"
    [ "$(table_entries "$md" '### Structural preferences')" -ge 1 ] \
      || fail "$skill: no table entries under '### Structural preferences' in '## Anti-patterns'"
  fi

  # Fixture dir normally matches the skill name; tests/fixtures/fastapi/ predates
  # the -architecture suffix, so fall back to the unsuffixed name.
  fixture_dir="tests/fixtures/$skill"
  [ -d "$fixture_dir" ] || fixture_dir="tests/fixtures/${skill%-architecture}"

  fixtures=("$fixture_dir"/bad_*.py)
  if [ ${#fixtures[@]} -eq 0 ]; then
    fail "$skill: no paired fixture at tests/fixtures/$skill/bad_*.py"
  else
    for f in "${fixtures[@]}"; do
      grep -q 'Intentional test fixture' "$f" \
        || fail "$f: missing the 'Intentional test fixture' docstring marker"
    done
  fi

  # The fixture is only half of it — the check.sh that grades the skill against it
  # is what contributors are required to run before opening a PR, and it has to be
  # executable for that instruction to work.
  if [ ! -f "$fixture_dir/check.sh" ]; then
    fail "$skill: no regression check at tests/fixtures/$skill/check.sh"
  elif [ ! -x "$fixture_dir/check.sh" ]; then
    fail "$fixture_dir/check.sh is not executable (chmod +x)"
  fi
done

version=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' .claude-plugin/plugin.json \
  | head -1 | sed -E 's/.*"([^"]*)"$/\1/')
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "plugin.json version '$version' is not semver (X.Y.Z)"

if [ "$FAIL" -eq 0 ]; then
  echo "OK: ${#skill_dirs[@]} skills each have SKILL.md with Scope + both anti-pattern tables, a marked fixture, and an executable check.sh; plugin.json version $version is valid semver"
else
  echo "FAIL: structural assertions failed — see above"
  exit 1
fi
