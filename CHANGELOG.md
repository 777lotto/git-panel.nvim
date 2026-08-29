# Changelog

Notable changes are recorded here. Releases follow semantic versioning.

## Unreleased

### Added

- Responsive repository overview data, concurrent Git snapshots, contextual
  wide-layout details, and informative compact/empty states.
- A production-branch hook that can request a focused GitPanel lock refresh in
  `nvim-config` without floating user installs away from tested commits.
- Read-only Actions, Issues, and Pull Requests views with asynchronous `gh` and
  curl transports, per-repository caches, explicit loading/error states, and
  in-editor or browser details.
- GitHub.com, GHE.com, and configured GitHub Enterprise remote discovery.
- `github.remote_path_prefix` and `github.allow_insecure_http`, which let the
  Actions, Issues, and Pull Requests views work against a broker or reverse
  proxy that mounts repositories under a path prefix and publishes a
  GitHub-compatible REST API, including a plaintext private-network endpoint.
  A configured `github.api_url` host is now discoverable as well. Default
  GitHub.com and GHE behaviour is unchanged.
- `setup()` options for GitHub transport, repository overrides, cache timing,
  and synchronous or asynchronous short-lived token providers.
- An opt-in `signed_git` pull-request merge backend that verifies the exact PR
  head, creates a locally signed merge in a temporary worktree, and pushes with
  non-force and lease-protected Git operations.
- Focused provider, response-normalization, redaction, and help-renderer tests.

### Changed

- The panel now exposes five views with forward/reverse tab cycling and numeric
  navigation.
- The `?` key guide is structured, semantically highlighted, responsive, and
  scrollable on shorter editors.
- Repository links now distinguish actionable Issues from community Discussions
  and connect cross-repository work to Neovim Workspace.
- GitHub Actions use `actions/checkout` v7.
- The `gh` transport now follows the endpoint-first `gh api` contract and sets
  `GH_HOST`, allowing API-only GitHub App wrappers without changing the default
  experience for regular `gh` users.

### Security

- A bearer token is never sent over plaintext HTTP to a non-loopback host, even
  when `github.allow_insecure_http` is enabled; the request fails closed with a
  configuration error instead.
- GitHub credentials are never persisted, rendered, notified, or placed in
  process arguments. Raw GitHub App private keys remain outside Neovim; curl
  authorization headers travel over standard input.
- Pull-request branch cleanup is restricted to same-repository heads. Signed
  Git cleanup uses an exact-SHA force-with-lease and never targets fork heads.

## 0.1.0 - 2026-08-15

### Added

- Keyboard-driven staged, unstaged, untracked, history, and push views.
- Branch, worktree, merge, conflict-resolution, commit, and remote actions.
- Commit-signature indicators and explicit signed-commit failure handling.
- Optional first-push GitHub repository creation through `gh`.
- Linux compatibility checks for Neovim 0.10, 0.11, and 0.12.
- macOS smoke coverage, issue forms, contribution guidance, and security policy.

[Unreleased]: https://github.com/777lotto/git-panel.nvim/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/777lotto/git-panel.nvim/releases/tag/v0.1.0
