# Contributing

Issues and pull requests should describe the Git workflow problem first, then
the proposed behavior.

## Branch model

- `bet` is the production/default branch.
- `bluff` is the persistent integration branch.
- Short-lived work branches start from and return to `bluff`.
- A `bluff` → `bet` pull request promotes a tested release candidate.

Do not target `bet` directly for ordinary changes.

## Local checks

Run these from the repository root with Neovim 0.10 or newer:

```sh
nvim --headless --clean -l scripts/check-lua.lua .
nvim --headless -u tests/minimal_init.lua -l tests/smoke.lua
nvim --headless -u tests/minimal_init.lua -c "helptags doc" -c quit
git diff --check
git diff --exit-code -- doc/tags
```

Keep the plugin dependency-free unless a proposal demonstrates that a new
dependency materially improves the core Git workflow. Add a smoke assertion or
focused reproduction for bug fixes when practical.

Commits should be signed with a GitHub-verified GPG, SSH, or S/MIME signature.
Open the pull request into `bluff`, complete the checklist, and wait for CI.
