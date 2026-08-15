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
  panel.open("split")

  assert(panel.mode == "split", "panel did not open in split mode")
  assert(vim.uv.fs_realpath(panel.root) == vim.uv.fs_realpath(fixture), "wrong repository root")
  local rendered = table.concat(vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false), "\n")
  assert_contains(rendered, "Branches")
  assert_contains(rendered, "Unstaged  (1)")
  assert_contains(rendered, "Untracked  (1)")

  panel.stage_all()
  local staged = git({ "diff", "--cached", "--name-only" })
  assert_contains(staged, "tracked.txt")
  assert_contains(staged, "untracked.txt")

  panel.unstage_all()
  assert(git({ "diff", "--cached", "--name-only" }) == "", "unstage-all left index changes")

  panel.toggle_view()
  assert(panel.view == "history", "history view did not activate")
  panel.toggle_layout()
  assert(panel.mode == "tab", "layout did not toggle to tab mode")
  panel.close()
end

local ok, message = xpcall(run, debug.traceback)
if panel then pcall(panel.close) end
vim.fn.delete(fixture, "rf")
if not ok then error(message) end

print("GitPanel smoke test passed")
