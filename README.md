# git-panel.nvim

[![CI](https://github.com/777lotto/git-panel.nvim/actions/workflows/ci.yml/badge.svg?branch=bet)](https://github.com/777lotto/git-panel.nvim/actions/workflows/ci.yml)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io/)
[![Release](https://img.shields.io/github/v/release/777lotto/git-panel.nvim)](https://github.com/777lotto/git-panel.nvim/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A dependency-free Git dashboard for Neovim. It keeps branches, worktrees,
staged and unstaged changes, conflicts, local-only commits, and push history in
one keyboard-driven panel.

## Highlights

- Separate work and history views with foldable sections.
- Branch and worktree creation, switching, renaming, merging, and removal.
- Staging, discarding, signing-aware commits, and explicit conflict actions.
- Pull, fetch, push, and first-push repository publication.
- Verified-signature indicators in commit history.
- No Neovim plugin dependencies.

## Requirements

- Neovim 0.10 or newer
- Git available on `PATH`

The GitHub CLI (`gh`) is optional. When installed and authenticated, it lets the
panel create a GitHub repository during the first push. Without it, the panel
can attach and push to any existing Git remote URL.

## Installation

With lazy.nvim:

```lua
{
  "777lotto/git-panel.nvim",
  cmd = { "GitPanel", "GitPanelSplit" },
  keys = {
    { "<leader>gg", "<cmd>GitPanel<cr>", desc = "Git dashboard" },
    { "<leader>gG", "<cmd>GitPanelSplit<cr>", desc = "Git dashboard (split)" },
  },
}
```

The default `bet` branch is production. Pin a release tag for a deliberately
stable installation, or use `branch = "bluff"` only when testing integration
work.

With Neovim's native packages:

```sh
git clone https://github.com/777lotto/git-panel.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/git-panel.nvim
nvim --headless -c "helptags ALL" -c quit
```

## Commands

- `:GitPanel` opens the full dashboard in a tab.
- `:GitPanelSplit` opens it as a left split.

The Lua API is available through `require("git_panel")`; its primary entry
point is `require("git_panel").open("tab")` or `.open("split")`.

## Main controls

| Key | Action |
| --- | --- |
| `<Tab>` | Toggle work and history views |
| `<CR>` | Act on the item under the cursor (LF/keypad Enter also work) |
| `s` / `u` | Stage / unstage the selected file |
| `S` / `U` | Stage / unstage all |
| `c` / `C` | Commit staged / stage all and commit |
| `a` | Amend the last commit |
| `b` / `R` / `d` | Create / rename / delete a branch |
| `W` | Create a worktree |
| `F` / `P` / `f` | Pull / push-or-publish / fetch |
| `L` | Toggle tab and split layouts |
| `r` | Refresh |
| `?` | Show the complete in-panel help |
| `q` | Close |

Conflict workflows expose take-ours/take-theirs, continue, and abort actions;
remote branch renames use leases and avoid overwriting an unrelated ref.

When `P` is pressed in a repository with no configured remote, GitPanel offers
two paths:

- create a private, public, or internal GitHub repository with `gh repo create`,
  add it as `origin`, and push the current branch;
- attach an already-created URL as `origin` and push the current branch, which
  works with GitLab, Bitbucket, self-hosted Git, or a bare repository.

Publishing requires at least one local commit. If a remote already exists but
the branch has no upstream, `P` selects the remote when needed and pushes with
upstream tracking.

## Platform support

| Platform | Status | CI |
| --- | --- | --- |
| Linux | Supported | Neovim 0.10.4, 0.11.7, and 0.12.4 |
| macOS | Supported | Neovim 0.12.4 smoke test |
| Windows | Untested | Contributions welcome |

Platform behavior is kept in the implementation and tested in Actions. It is
not split into operating-system branches or GitHub Environments.

## Branch and release model

- `bet` is the production/default branch.
- `bluff` is the persistent integration branch.
- Focused branches merge into `bluff`; releases promote `bluff` into `bet`.
- Signed `vX.Y.Z` tags identify releases.

See [CONTRIBUTING.md](CONTRIBUTING.md) for checks and pull-request guidance.

## Community and roadmap

Use [Issues](https://github.com/777lotto/git-panel.nvim/issues) for reproducible,
actionable work. Questions, setup showcases, and exploratory ideas belong in
[Discussions](https://github.com/777lotto/git-panel.nvim/discussions). Work that
spans this plugin and `nvim-config` is planned in the public
[Neovim Workspace](https://github.com/users/777lotto/projects/5).

## Project layout

```text
git-panel.nvim/
├── .github/                 # CI, issue forms, and contribution templates
├── lua/git_panel/init.lua   # dashboard implementation and public Lua API
├── plugin/git-panel.lua     # lightweight command registration
├── doc/git-panel.txt        # :help git-panel
├── scripts/check-lua.lua    # dependency-free compilation check
└── tests/                   # isolated Git fixture and dashboard smoke test
```

Run `:help git-panel` for the complete in-editor reference.

## License

git-panel.nvim is available under the [MIT License](LICENSE).
