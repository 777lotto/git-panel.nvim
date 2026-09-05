# Automatic releases

After all `CI` jobs succeed for a push to `bluff`, `Release tested plugin`
publishes the tested commit if it is still the current branch head. PR runs,
failed or cancelled runs, and superseded commits cannot publish.

CI uses its repository-scoped `GITHUB_TOKEN` with Contents write permission.
It creates unsigned lightweight version tags: the first is `v0.1.0`, followed
by a patch increment above the highest stable `vX.Y.Z` tag. Prerelease tags
are excluded. Intentional minor or major milestones can still be tagged and
released by an operator; subsequent automatic releases increment that line.
Existing tags are never moved. Agent Manager has a separate signed-tag policy
and is not affected by this Lua plugin policy.

A rerun reuses a stable tag and published release already assigned to the
same commit. If only the tag exists, it finishes publication. Draft or
prerelease collisions and API errors stop the workflow. GitHub generates the
release notes from repository history; this does not rewrite CHANGELOG.md.

After publication, the workflow directly sends the released tag and exact
commit to `777lotto/nvim-config`. This direct step is necessary because
releases created with `GITHUB_TOKEN` do not trigger another release-event
workflow. The existing `Notify nvim-config` workflow remains a recovery path
for operator-published releases and manual notifications.

The operator provisions `NVIM_CONFIG_DISPATCH_TOKEN`, scoped to nvim-config
with Contents write permission, in this plugin repository. If it is missing,
the Release remains published and notification fails visibly. Configure the
secret and rerun the workflow; the version is reused. No signing secret or
credential is stored in the agent workspace.

nvim-config receives a dependency PR that changes the plugin lock entry.
Its separate dependency merge automation validates and merges that PR after
CI passes. That adoption does not publish an ordinary nvim-config Release or
update an already-running Neovim process. The workflow files must first be
merged into `bluff` to activate this behavior.

Run `bash scripts/test-release-tested.sh` for isolated API/Git fixtures covering
first publication, patch numbering, reruns, interrupted publication, stale CI,
API failure, tag collisions, and draft collisions. The main CI runs these
fixtures before a release can be published.
