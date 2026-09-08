#!/usr/bin/env bash
# Regenerate CHANGELOG.md from the repository's v* tags.
#
# The whole file is rebuilt from git history every time rather than appended to, so
# the result is idempotent: running it twice changes nothing, and a release that
# fails halfway leaves no half-written file to repair by hand. That also means it
# can be run locally and produce exactly what CI produces.
#
# Usage:
#   ci/changelog.sh [--output CHANGELOG.md] [--repo-url https://github.com/owner/repo]
set -euo pipefail

OUTPUT="CHANGELOG.md"
REPO_URL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --output)   OUTPUT="$2"; shift 2 ;;
    --repo-url) REPO_URL="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# In Actions these are already set; locally, fall back to the origin remote.
if [ -z "$REPO_URL" ]; then
  if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    REPO_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}"
  else
    remote="$(git remote | head -n1)"
    REPO_URL="$(git remote get-url "$remote" 2>/dev/null || true)"
    REPO_URL="${REPO_URL%.git}"
    REPO_URL="${REPO_URL/git@github.com:/https://github.com/}"
  fi
fi

tags="$(git tag --list 'v*' --sort=-v:refname)"

{
  echo "# Changelog"
  echo
  echo "Generated from git history by \`ci/changelog.sh\`, rewritten in full on every"
  echo "release. Edits made here by hand will be overwritten."
  echo

  if [ -z "$tags" ]; then
    echo "_No releases yet. Tag a commit as \`vX.Y.Z\` to create the first one._"
  fi

  while IFS= read -r tag; do
    [ -n "$tag" ] || continue

    date="$(git log -1 --format=%ad --date=short "$tag")"
    # The tag reachable from this one's parent: the release this one actually
    # follows, even if tags were created out of version order.
    prev="$(git describe --tags --abbrev=0 --match 'v*' "${tag}^" 2>/dev/null || true)"

    echo "## ${tag} - ${date}"
    echo

    if [ -n "$prev" ]; then
      range="${prev}..${tag}"
    else
      range="$tag"
    fi

    # Merge commits describe branch topology, not changes anyone wants to read.
    if ! git log --no-merges --pretty='- %s (%h)' "$range" | grep .; then
      echo "_No commits recorded for this release._"
    fi
    echo

    if [ -n "$prev" ] && [ -n "$REPO_URL" ]; then
      echo "[Full diff](${REPO_URL}/compare/${prev}...${tag})"
      echo
    fi
  done <<< "$tags"
} > "$OUTPUT"

echo "Wrote $OUTPUT ($(grep -c '^## ' "$OUTPUT") release sections)"
