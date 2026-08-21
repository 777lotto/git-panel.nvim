# git-panel.nvim

[![CI](https://github.com/777lotto/git-panel.nvim/actions/workflows/ci.yml/badge.svg?branch=bet)](https://github.com/777lotto/git-panel.nvim/actions/workflows/ci.yml)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io/)
[![Release](https://img.shields.io/github/v/release/777lotto/git-panel.nvim)](https://github.com/777lotto/git-panel.nvim/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A dependency-free local Git dashboard for Neovim with optional GitHub
repository views. It keeps branches, worktrees, changes, conflicts, commits,
workflow runs, issues, and pull requests in one keyboard-driven panel — and
lets you review, comment on, and merge pull requests without leaving it.

## Highlights

- Five first-class views: Changes, History, Actions, Issues, and Pull Requests.
- Non-blocking local snapshots: independent Git reads run concurrently and
  stale callbacks cannot replace a newer repository state.
- A responsive full-tab workspace with a live diff/object context rail on wide
  screens; the compact split keeps the focused navigation layout.
- Branch and worktree creation, switching, renaming, merging, and removal.
- Staging, discarding, signing-aware commits, and explicit conflict actions.
- Pull, fetch, push, and first-push repository publication.
- Asynchronous GitHub synchronization through `gh` or `curl` with no UI stalls.
- Structured, highlighted, responsive `?` key guide.
- Verified-signature indicators in commit history.
- No Neovim plugin dependencies.

## Requirements

- Neovim 0.10 or newer
- Git available on `PATH`

GitPanel's local views require nothing else. GitHub views use one optional
transport:

- authenticated [GitHub CLI](https://cli.github.com/) (`gh`) — recommended;
- `curl`, authenticated through a token provider for private repositories or
  anonymous for public repositories.

The `gh` CLI also enables GitHub repository creation during the first push.
Without it, the panel can still attach and push to any existing Git remote URL.

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
| `<Tab>` / `<S-Tab>` | Move to the next / previous view |
| `1`–`5` | Jump to Changes, History, Actions, Issues, or Pull Requests |
| `<CR>` | Act on the item under the cursor (LF/keypad Enter also work) |
| `s` / `u` | Stage / unstage the selected file |
| `S` / `U` | Stage / unstage all |
| `c` / `C` | Commit staged / stage all and commit |
| `a` | Amend the last commit |
| `b` / `R` / `d` | Create / rename / delete a branch |
| `W` | Create a worktree |
| `F` / `P` / `f` | Pull / push-or-publish / fetch |
| `L` | Toggle tab and split layouts |
| `r` | Refresh local state and synchronize GitHub repository context |
| `gx` | Open the selected GitHub item in a browser |
| `go` / `gd` | Check out / diff the selected pull request against its base |
| `gc` / `gm` | Comment on / merge the selected pull request (confirm; uses the configured merge backend) |
| `?` / `g?` | Show the highlighted, scrollable key guide |
| `q` | Close |

Conflict workflows expose take-ours/take-theirs, continue, and abort actions;
remote branch renames use leases and avoid overwriting an unrelated ref.

The full-tab layout adapts at 120 columns. At wider sizes, the dashboard uses
the left side for repository state and the right side for context: repository
and remote metadata by default, then a live diff, commit stat, branch tip,
worktree status, tag, stash, push, issue, workflow, or pull-request summary as
the cursor moves. Below that threshold it collapses to one pane. The split
layout remains a fixed-width, compact control surface.

When `P` is pressed in a repository with no configured remote, GitPanel offers
two paths:

- create a private, public, or internal GitHub repository with `gh repo create`,
  add it as `origin`, and push the current branch;
- attach an already-created URL as `origin` and push the current branch, which
  works with GitLab, Bitbucket, self-hosted Git, or a bare repository.

Publishing requires at least one local commit. If a remote already exists but
the branch has no upstream, `P` selects the remote when needed and pushes with
upstream tracking.

## GitHub repository views

The Actions and Issues views are read-only; the Pull Requests view adds
review-and-land actions that always confirm before writing. GitPanel resolves
the current repository from a GitHub.com or `*.ghe.com` remote, preferring
`origin`, then caches repository metadata and each view independently. Open
issue/PR counts and the latest workflow state appear in the view bar. The
context rail adds visibility, default branch, and description without adding
vanity metrics. Opening a view renders cached
content immediately and starts a background refresh when the cache is stale.
Loading, empty, authentication, permission, rate-limit, network, and stale-data
states are shown inside the panel.

- Actions shows recent workflow status, conclusion, branch, event, actor, and
  update date.
- Issues shows open issues, excluding pull requests returned by GitHub's Issues
  endpoint.
- Pull Requests shows open PRs, draft state, head/base branches, author, and
  update date.
- `<CR>` opens a Markdown summary in Neovim; `gx` opens the canonical GitHub URL.
- On a pull-request row: `go` fetches and checks out the head branch, `gd`
  opens the full `base...head` diff in a buffer, `gc` posts a conversation
  comment, and `gm` creates a merge commit using the configured backend. After
  a merge, GitPanel deletes a same-repository remote head branch, prunes, and —
  when you were on the PR branch — returns you to the base branch and
  fast-forwards it. Cross-repository head branches are never deleted from the
  base repository.

Zero-configuration `gh` authentication is the preferred path: run
`gh auth login`, or provide one of the token environment variables supported by
GitHub CLI. GitPanel calls `gh api` directly and never copies the stored token
into Lua configuration. `github.gh_command` may instead name a compatible API
wrapper; GitPanel invokes `COMMAND api ENDPOINT [flags]` and supplies `GH_HOST`,
so the wrapper does not need to expose the other `gh` command groups.

Optional settings:

```lua
require("git_panel").setup({
  help = {
    border = "rounded",
    max_width = 88,
  },
  github = {
    enabled = true,
    transport = "auto",       -- "auto", "gh", or "curl"
    repository = nil,          -- "OWNER/REPO"; nil detects a Git remote
    host = nil,                -- required to identify a custom GHES host
    api_url = nil,             -- custom HTTPS REST base; auto selects curl
    refresh_interval = 60,     -- seconds
    per_page = 30,             -- 1..100
    timeout = 15000,           -- milliseconds
    token_provider = nil,
    merge_backend = "api",     -- "api" or "signed_git"
    gh_command = "gh",
    curl_command = "curl",
  },
})
```

`merge_backend = "api"` is the portable default. It asks GitHub to merge only
if the head still matches the SHA shown in GitPanel and, for a same-repository
pull request, deletes the head ref through the REST API.

`merge_backend = "signed_git"` is an opt-in capability for anyone with Git
commit signing and remote push authentication configured. It fetches the
current base and the pull request's exact advertised head SHA, creates a
`--no-ff --gpg-sign` merge in a temporary worktree, verifies that the result
contains a cryptographic signature and two parents, then pushes the base with a
normal non-force Git push. A same-repository head branch is deleted with an
exact-SHA lease; a fork branch is left alone. If signing fails or the PR head
changed, nothing is pushed and there is no unsigned or API fallback. Git's
configured OpenPGP, SSH, or S/MIME signing format is used.

For example, an API-only GitHub App wrapper can be combined with locally signed
Git transport without coupling the two mechanisms:

```lua
require("git_panel").setup({
  github = {
    gh_command = vim.fn.expand("~/.local/bin/gh-app"),
    merge_backend = "signed_git",
  },
})
```

The signed backend needs permission to push the base through the repository's
existing Git remote. Branch protection, rulesets, and merge queues can reject
that push; choose the API backend when GitHub must perform or queue the merge.
Comments and all GitHub view data continue to use the selected API transport in
either mode.

The curl transport needs a bearer token for private repositories. A synchronous
provider can read a short-lived token from an existing secret source:

```lua
require("git_panel").setup({
  github = {
    transport = "curl",
    token_provider = function(context)
      return vim.env.GITHUB_TOKEN
    end,
  },
})
```

Providers that mint an expiring GitHub App installation token can resolve it
asynchronously. Return `true` to signal that the provider will invoke
`done(token, error)` later:

```lua
require("git_panel").setup({
  github = {
    token_provider = function(context, done)
      vim.system({ "my-github-app-token-helper", context.repository },
        { text = true }, function(result)
          vim.schedule(function()
            if result.code == 0 then
              done(vim.trim(result.stdout))
            else
              done(nil, "GitHub App token helper failed")
            end
          end)
        end)
      return true
    end,
  },
})
```

GitHub App user access tokens and installation access tokens are supported as
bearer tokens. The App needs repository **Actions: read**, **Issues: read**, and
**Pull requests: read** permissions. `gc` additionally needs permission to
write issue or pull-request comments (**Issues: write** or **Pull requests:
write**). The API merge backend needs
**Contents: write** for merging and same-repository branch deletion; the signed
Git backend uses Git push authentication instead. A raw App private key is
deliberately not accepted: it is a long-lived signing credential used to mint
an installation token, and should stay in an external helper or vault.
Installation tokens expire after one hour, so GitPanel invokes the provider for
every request batch.
See GitHub's documentation for [App authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/about-authentication-with-a-github-app)
and [installation access tokens](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app).

Tokens are never persisted, rendered, notified, or placed in process arguments.
The `gh` transport passes a provider token through the appropriate environment
variable; the curl transport sends its authorization header over standard
input, ignores user-level curl configuration, and does not follow redirects.

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

Each push to production `bet` can request a focused `git-panel.nvim` lockfile
refresh in `777lotto/nvim-config`. Configure the plugin repository secret
`NVIM_CONFIG_DISPATCH_TOKEN` with a fine-grained token scoped only to
`777lotto/nvim-config` and its Contents permission set to write. If the secret
is absent, the notification workflow exits successfully with a setup notice;
it never broadens repository or network access.

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
├── lua/git_panel/init.lua   # dashboard, actions, rendering, and public Lua API
├── lua/git_panel/model.lua  # concurrent local Git snapshot and parsers
├── lua/git_panel/github.lua # GitHub discovery, transports, and response models
├── lua/git_panel/help.lua   # structured responsive key-guide renderer
├── plugin/git-panel.lua     # lightweight command registration
├── doc/git-panel.txt        # :help git-panel
├── scripts/check-lua.lua    # dependency-free compilation check
└── tests/                   # provider/unit tests and isolated Git smoke fixture
```

Run `:help git-panel` for the complete in-editor reference.

## License

git-panel.nvim is available under the [MIT License](LICENSE).
