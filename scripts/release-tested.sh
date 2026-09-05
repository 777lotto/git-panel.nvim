#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_REPOSITORY:?}"
: "${TESTED_COMMIT:?}"
: "${GITHUB_OUTPUT:?}"
[[ "$TESTED_COMMIT" =~ ^[0-9a-f]{40}$ ]]
api="repos/$GITHUB_REPOSITORY"

# A queued old success must not replace a newer release or dependency pin.
current="$(gh api "$api/git/ref/heads/bluff" --jq .object.sha)"
if [[ "$current" != "$TESTED_COMMIT" ]]; then
  echo "Skipping superseded CI commit $TESTED_COMMIT."
  exit 0
fi
git cat-file -e "$TESTED_COMMIT^{commit}"

tags="$(git tag --list 'v*' --sort=-version:refname)"
latest=""
tag=""
while IFS= read -r candidate; do
  [[ "$candidate" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || continue
  [[ -n "$latest" ]] || latest="$candidate"
  if [[ "$(git rev-list -n 1 "$candidate")" == "$TESTED_COMMIT" ]]; then
    tag="$candidate"
    break
  fi
done <<< "$tags"

if [[ -z "$tag" ]]; then
  tag=v0.1.0
  if [[ -n "$latest" ]]; then
    version="${latest#v}"
    IFS=. read -r major minor patch <<< "$version"
    tag="v$major.$minor.$((patch + 1))"
  fi
  # Reserve the exact ref atomically. A collision fails; never move a tag.
  gh api --method POST "$api/git/refs" \
    -f "ref=refs/tags/$tag" -f "sha=$TESTED_COMMIT"
fi

# Resume a run interrupted after creating its tag or release. API failures
# remain failures; do not confuse an unavailable API with a missing release.
releases="$(gh api --paginate "$api/releases" --slurp)"
existing="$(jq -c --arg tag "$tag" 'add // [] | map(select(.tag_name == $tag))' <<< "$releases")"
if [[ "$(jq length <<< "$existing")" == 0 ]]; then
  gh release create "$tag" --repo "$GITHUB_REPOSITORY" \
    --verify-tag --title "$tag" --generate-notes --latest
else
  jq -e 'length == 1 and .[0].draft == false and .[0].prerelease == false' \
    <<< "$existing" >/dev/null
  echo "Reusing published release $tag."
fi
printf 'tag=%s\n' "$tag" >> "$GITHUB_OUTPUT"
