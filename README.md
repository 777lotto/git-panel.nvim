# git-panel.nvim

A dependency-free Git dashboard for Neovim. It keeps branches, worktrees,
staged and unstaged changes, conflicts, local-only commits, and push history in
one keyboard-driven panel.

This directory is a complete plugin package, not configuration code embedded
in an `init.lua`. It can be moved to its own repository without changing its
Lua module or command files.

## Requirements

- Neovim 0.10 or newer
- Git available on `PATH`

No Lua plugin dependencies are required.

## Installation

The parent config loads this checkout directly:

```lua
{
  dir = vim.fn.stdpath("config") .. "/local-plugins/git-panel.nvim",
  cmd = { "GitPanel", "GitPanelSplit" },
  keys = {
    { "<leader>gg", "<cmd>GitPanel<cr>" },
    { "<leader>gG", "<cmd>GitPanelSplit<cr>" },
  },
}
```

After publishing this directory as its own repository, replace `dir` with its
GitHub slug, for example `"owner/git-panel.nvim"`. No source extraction is
needed.

## Commands

- `:GitPanel` opens the full dashboard in a tab.
- `:GitPanelSplit` opens it as a left split.

The Lua API is also available through `require("git_panel")`; its primary entry
point is `require("git_panel").open("tab")` or `.open("split")`.

## Main controls

| Key | Action |
| --- | --- |
| `<Tab>` | Toggle work and history views |
| `<CR>` | Act on the item under the cursor |
| `s` / `u` | Stage / unstage the selected file |
| `S` / `U` | Stage / unstage all |
| `c` / `C` | Commit staged / stage all and commit |
| `a` | Amend the last commit |
| `b` / `R` / `d` | Create / rename / delete a branch |
| `W` | Create a worktree |
| `F` / `P` / `f` | Pull / push / fetch |
| `L` | Toggle tab and split layouts |
| `r` | Refresh |
| `?` | Show the complete in-panel help |
| `q` | Close |

Conflict workflows expose take-ours/take-theirs, continue, and abort actions;
remote branch renames use leases and avoid overwriting an unrelated ref.

## Project layout

```text
git-panel.nvim/
├── lua/git_panel/init.lua  # dashboard implementation and public Lua API
├── plugin/git-panel.lua    # lightweight command registration
└── doc/git-panel.txt       # :help git-panel
```

Run `:helptags ALL` after a manual installation if your package manager does
not generate help tags automatically.
