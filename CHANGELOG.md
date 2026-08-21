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
- `setup()` options for GitHub transport, repository overrides, cache timing,
  and synchronous or asynchronous short-lived token providers.
- Focused provider, response-normalization, redaction, and help-renderer tests.

### Changed

- The panel now exposes five views with forward/reverse tab cycling and numeric
  navigation.
- The `?` key guide is structured, semantically highlighted, responsive, and
  scrollable on shorter editors.
- Repository links now distinguish actionable Issues from community Discussions
  and connect cross-repository work to Neovim Workspace.
- GitHub Actions use `actions/checkout` v7.

### Security

- GitHub credentials are never persisted, rendered, notified, or placed in
  process arguments. Raw GitHub App private keys remain outside Neovim; curl
  authorization headers travel over standard input.

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
