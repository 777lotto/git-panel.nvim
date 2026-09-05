#!/usr/bin/env bash
set -euo pipefail
root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
export GITHUB_REPOSITORY=fixture/plugin GITHUB_OUTPUT=/dev/stdout
export TESTED_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

# Exercise publication without network access, credentials, or real tags.
git() {
  case "$1" in
    cat-file) return 0 ;;
    tag)
      case "$SCENARIO" in
        first|stale|collision|api_failure) printf '\n' ;;
        *) printf 'v9.0.0-rc.1\nv0.2.9\nv0.2.8\n' ;;
      esac
      ;;
    rev-list)
      case "$SCENARIO" in
        rerun|partial|draft) printf '%s\n' "$TESTED_COMMIT" ;;
        *) printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
      esac
      ;;
    *) echo "Unexpected git call: $*" >&2; return 1 ;;
  esac
}
gh() {
  case "$*" in
    'api repos/fixture/plugin/git/ref/heads/bluff --jq .object.sha')
      if [[ "$SCENARIO" == stale ]]; then
        printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
      else
        printf '%s\n' "$TESTED_COMMIT"
      fi
      ;;
    'api --method POST repos/fixture/plugin/git/refs '*)
      [[ "$*" == *"sha=$TESTED_COMMIT"* ]]
      if [[ "$SCENARIO" == collision ]]; then return 1; fi
      printf 'reserved:%s\n' "$*"
      ;;
    'api --paginate repos/fixture/plugin/releases --slurp')
      case "$SCENARIO" in
        api_failure) return 1 ;;
        rerun) printf '[[{"tag_name":"v0.2.9","draft":false,"prerelease":false}]]\n' ;;
        draft) printf '[[{"tag_name":"v0.2.9","draft":true,"prerelease":false}]]\n' ;;
        *) printf '[[]]\n' ;;
      esac
      ;;
    'release create '*)
      [[ "$*" == *--verify-tag* && "$*" == *--generate-notes* ]]
      printf 'published:%s\n' "$3"
      ;;
    *) echo "Unexpected gh call: $*" >&2; return 1 ;;
  esac
}
export -f gh git
for SCENARIO in first patch rerun partial stale collision api_failure draft; do
  export SCENARIO
  status=0
  output="$(bash "$root/scripts/release-tested.sh" 2>&1)" || status=$?
  case "$SCENARIO" in
    first) [[ "$status" == 0 && "$output" == *'published:v0.1.0'* && "$output" == *'tag=v0.1.0'* ]] ;;
    patch) [[ "$status" == 0 && "$output" == *'published:v0.2.10'* ]] ;;
    rerun) [[ "$status" == 0 && "$output" != *published:* && "$output" != *reserved:* && "$output" == *'tag=v0.2.9'* ]] ;;
    partial) [[ "$status" == 0 && "$output" == *'published:v0.2.9'* && "$output" != *reserved:* ]] ;;
    stale) [[ "$status" == 0 && "$output" != *published:* && "$output" != *reserved:* && "$output" != *'tag='* ]] ;;
    *) [[ "$status" != 0 && "$output" != *published:* && "$output" != *'tag='* ]] ;;
  esac
done
echo "Release publication fixtures passed"
