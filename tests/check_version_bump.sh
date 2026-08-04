#!/usr/bin/env bash
# Validates the .claude-plugin manifests and enforces the version-bump rule from
# CONTRIBUTING.md: if any skill or command content changed relative to the BASE
# commit, plugin.json's version must be greater than it was AT THAT BASE, and
# marketplace.json must carry the same number.
#
# Usage: tests/check_version_bump.sh [base-ref-or-sha]
#   base defaults to HEAD^ (previous commit). CI passes the PR base sha or the
#   pre-push sha; the real comparison point is merge-base(base, HEAD), so a base
#   branch that moved on after the branch diverged does not skew the diff.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PLUGIN=.claude-plugin/plugin.json
MARKET=.claude-plugin/marketplace.json

fail=0
die() { echo "FAIL: $*" >&2; fail=1; }

# 1. manifests parse at all
for f in "$PLUGIN" "$MARKET"; do
  jq empty "$f" 2>/dev/null || die "$f is not valid JSON"
done
[ "$fail" -eq 0 ] || exit 1

# 2. the two copies of the version agree
name=$(jq -r '.name // empty' "$PLUGIN")
now=$(jq -r '.version // empty' "$PLUGIN")
market_now=$(jq -r --arg n "$name" '.plugins[] | select(.name == $n) | .version' "$MARKET")
[ -n "$name" ] || die "$PLUGIN has no name field"
[ -n "$now" ]  || die "$PLUGIN has no version field"
if [ "$now" != "$market_now" ]; then
  die "version mismatch: $PLUGIN=$now vs $MARKET=${market_now:-<no entry for '$name'>}"
fi

# 3. resolve the base commit to compare against
base_in="${1:-}"
case "$base_in" in
  ""|0000000000000000000000000000000000000000) base_in="HEAD^" ;;
esac
if ! git rev-parse --verify --quiet "${base_in}^{commit}" >/dev/null; then
  echo "::warning::base '$base_in' not available (shallow clone, force-push, or root commit) - skipping version-bump check"
  exit "$fail"
fi
# merge-base, not the raw ref: on a PR this is the divergence point, so the diff
# is the branch's own changes and not whatever landed on main meanwhile.
base=$(git merge-base "$base_in" HEAD 2>/dev/null || echo "$base_in")
base=$(git rev-parse --short "$base")

# 4. did plugin content change?
changed=$(git diff --name-only "$base" HEAD -- 'skills/*/SKILL.md' 'commands/*.md')
if [ -z "$changed" ]; then
  echo "OK: no skill/command content changed vs $base - no version bump required (at $now)"
  exit "$fail"
fi

echo "changed plugin content vs $base:"
printf '%s\n' "$changed" | sed 's/^/  /'

base_version=$(git show "$base:$PLUGIN" 2>/dev/null | jq -r '.version // empty' || true)
if [ -z "$base_version" ]; then
  echo "::warning::no readable $PLUGIN at $base - treating as new plugin, skipping comparison"
  exit "$fail"
fi

echo "version: $base_version (base) -> $now (head)"
if [ "$now" = "$base_version" ]; then
  die "plugin content changed but $PLUGIN version is still $base_version - bump it (patch level minimum) and keep $MARKET in sync"
# ponytail: sort -V, not a real semver parser - fine for x.y.z, would mis-rank prerelease tags
elif [ "$(printf '%s\n%s\n' "$base_version" "$now" | sort -V | head -1)" != "$base_version" ]; then
  die "version went backwards: $base_version -> $now"
else
  echo "OK: version bumped $base_version -> $now"
fi

exit "$fail"
