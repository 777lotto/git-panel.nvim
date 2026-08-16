local panel
local fixture = vim.fn.tempname()

local function git(args)
  local command = { "git" }
  vim.list_extend(command, args)
  local result = vim.system(command, {
    cwd = fixture,
    text = true,
    env = { LC_ALL = "C", GIT_CONFIG_NOSYSTEM = "1" },
  }):wait()
  assert(
    result.code == 0,
    ("%s failed:\n%s"):format(table.concat(command, " "), result.stderr or "")
  )
  return result.stdout or ""
end

local function assert_contains(text, needle)
  assert(text:find(needle, 1, true), ("expected output to contain %q"):format(needle))
end

local function panel_text()
  return table.concat(vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false), "\n")
end

local github_fixtures = {
  actions = {
    {
      kind = "action", id = "101", number = 17, name = "CI", title = "test GitHub tabs",
      status = "completed", conclusion = "success", branch = "feat/github-workspace-tabs",
      event = "pull_request", actor = "gitpanel-ci", updated_at = "2026-08-16T12:00:00Z",
      url = "https://github.com/octo/git-panel/actions/runs/101",
    },
  },
  issues = {
    {
      kind = "issue", id = "201", number = 5, title = "Readable key guide", state = "open",
      author = "octo", labels = { "area:rendering", "accessibility" }, comments = 2,
      body = "Improve the key guide.", updated_at = "2026-08-16T12:00:00Z",
      url = "https://github.com/octo/git-panel/issues/5",
    },
  },
  pulls = {
    {
      kind = "pull", id = "301", number = 8, title = "Add repository views", state = "open",
      draft = true, author = "octo", head = "feature", base = "bluff", labels = {}, comments = 0,
      body = "Actions, Issues, and Pull Requests.", updated_at = "2026-08-16T12:00:00Z",
      url = "https://github.com/octo/git-panel/pull/8",
    },
  },
}

local function run()
  assert(vim.fn.mkdir(fixture, "p") == 1, "failed to create Git fixture")
  git({ "init", "--initial-branch=bet" })
  git({ "config", "user.name", "GitPanel CI" })
  git({ "config", "user.email", "git-panel@example.invalid" })
  git({ "config", "commit.gpgsign", "false" })

  vim.fn.writefile({ "initial" }, fixture .. "/tracked.txt")
  git({ "add", "tracked.txt" })
  git({ "commit", "-m", "initial fixture" })
  vim.fn.writefile({ "changed" }, fixture .. "/tracked.txt")
  vim.fn.writefile({ "new" }, fixture .. "/untracked.txt")

  assert(vim.fn.exists(":GitPanel") == 2, ":GitPanel command was not registered")
  assert(vim.fn.exists(":GitPanelSplit") == 2, ":GitPanelSplit command was not registered")

  vim.cmd("lcd " .. vim.fn.fnameescape(fixture))
  panel = require("git_panel")
  panel.setup({
    github = {
      repository = "octo/git-panel",
      client_factory = function()
        return {
          fetch = function(_, view, _, callback)
            vim.schedule(function()
              callback(nil, github_fixtures[view], { transport = "fixture" })
            end)
          end,
        }
      end,
    },
  })
  panel.open("split")

  assert(panel.mode == "split", "panel did not open in split mode")
  assert(vim.uv.fs_realpath(panel.root) == vim.uv.fs_realpath(fixture), "wrong repository root")
  local rendered = panel_text()
  assert_contains(rendered, "[* 1 Changes]")
  assert_contains(rendered, "[  5 Pull Requests]")
  assert_contains(rendered, "Branches")
  assert_contains(rendered, "Unstaged  (1)")
  assert_contains(rendered, "Untracked  (1)")

  panel.stage_all()
  local staged = git({ "diff", "--cached", "--name-only" })
  assert_contains(staged, "tracked.txt")
  assert_contains(staged, "untracked.txt")

  panel.unstage_all()
  assert(git({ "diff", "--cached", "--name-only" }) == "", "unstage-all left index changes")

  local help_buf, help_win = panel.help()
  assert(vim.api.nvim_win_is_valid(help_win), "help window did not open")
  local help_text = table.concat(vim.api.nvim_buf_get_lines(help_buf, 0, -1, false), "\n")
  assert_contains(help_text, "GitHub views")
  vim.api.nvim_win_close(help_win, true)
  vim.api.nvim_set_current_win(panel.win)

  panel.toggle_view()
  assert(panel.view == "history", "history view did not activate")
  panel.previous_view()
  assert(panel.view == "work", "previous view did not return to changes")

  panel.select_view(3)
  assert(vim.wait(1000, function() return panel_text():find("CI #17", 1, true) ~= nil end),
    "Actions view did not render async fixture")
  assert_contains(panel_text(), "synced")
  assert_contains(panel_text(), "via fixture")

  panel.select_view(4)
  assert(vim.wait(1000, function() return panel_text():find("#5", 1, true) ~= nil end),
    "Issues view did not render async fixture")
  local issue_line
  for index, line in ipairs(vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)) do
    if line:find("Readable key guide", 1, true) then issue_line = index; break end
  end
  assert(issue_line, "issue row was not mapped")
  vim.api.nvim_set_current_win(panel.win)
  vim.api.nvim_win_set_cursor(panel.win, { issue_line, 0 })
  panel.primary()
  assert_contains(vim.api.nvim_buf_get_name(0), "gitpanel://github/issue/201")
  vim.cmd("close")
  vim.api.nvim_set_current_win(panel.win)

  panel.select_view(5)
  assert(vim.wait(1000, function() return panel_text():find("#8", 1, true) ~= nil end),
    "Pull Requests view did not render async fixture")
  assert_contains(panel_text(), "Add repository views")

  panel.select_view(2)
  assert(panel.view == "history", "numeric view selection did not activate history")
  panel.toggle_layout()
  assert(panel.mode == "tab", "layout did not toggle to tab mode")
  panel.close()
end

local ok, message = xpcall(run, debug.traceback)
if panel then pcall(panel.close) end
vim.fn.delete(fixture, "rf")
if not ok then error(message) end

print("GitPanel smoke test passed")
