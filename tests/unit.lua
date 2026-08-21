local github = require("git_panel.github")
local help = require("git_panel.help")
local local_model = require("git_panel.model")

local function equal(actual, expected, message)
  assert(actual == expected, (message or "values differ") ..
    ("\nexpected: %s\nactual:   %s"):format(vim.inspect(expected), vim.inspect(actual)))
end

local function contains(text, needle, message)
  assert(text:find(needle, 1, true), message or ("expected text to contain %q"):format(needle))
end

local function test_remote_parsing()
  local ssh = assert(github.parse_remote("git@github.com:octo/widgets.nvim.git"))
  equal(ssh.host, "github.com")
  equal(ssh.repository, "octo/widgets.nvim")

  local https = assert(github.parse_remote("https://github.com/octo/widgets.nvim.git"))
  equal(https.owner, "octo")
  equal(https.name, "widgets.nvim")

  local ssh_over_443 = assert(github.parse_remote(
    "ssh://git@ssh.github.com:443/octo/widgets.nvim.git"))
  equal(ssh_over_443.host, "github.com")

  local enterprise = assert(github.parse_remote(
    "ssh://git@code.example.test:2222/platform/widgets.nvim.git"))
  equal(enterprise.host, "code.example.test:2222")
  equal(enterprise.repository, "platform/widgets.nvim")
  equal(github.api_base(enterprise, {}), "https://code.example.test:2222/api/v3")

  local ghe = assert(github.parse_remote("https://acme.ghe.com/platform/widgets.nvim"))
  equal(github.api_base(ghe, {}), "https://api.acme.ghe.com")
  assert(github.parse_remote("/tmp/local-repository") == nil, "local path parsed as GitHub remote")

  local configured = assert(github.resolve_repository("/does/not/matter", {
    repository = "octo/widgets.nvim",
    host = "github.com",
  }))
  equal(configured.repository, "octo/widgets.nvim")
end

local function test_normalization()
  local overview = github.normalize_overview({
    id = 1,
    name = "widgets",
    full_name = "octo/widgets",
    description = "Useful widgets",
    visibility = "private",
    private = true,
    default_branch = "bet",
    owner = { login = "octo" },
    html_url = "https://github.com/octo/widgets",
  })
  equal(#overview, 1)
  equal(overview[1].default_branch, "bet")
  equal(overview[1].visibility, "private")

  local actions = github.normalize_actions({
    workflow_runs = {
      {
        id = 10,
        run_number = 42,
        name = "CI",
        display_title = "test changes",
        status = "completed",
        conclusion = "success",
        head_branch = "bet",
        actor = { login = "octo" },
        html_url = "https://github.com/octo/widgets/actions/runs/10",
      },
    },
  })
  equal(#actions, 1)
  equal(actions[1].number, 42)
  equal(actions[1].conclusion, "success")

  local issues = github.normalize_issues({
    {
      id = 20,
      number = 5,
      title = "Readable key guide",
      user = { login = "octo" },
      labels = { { name = "area:rendering" }, "accessibility" },
      comments = 2,
      html_url = "https://github.com/octo/widgets/issues/5",
    },
    {
      id = 21,
      number = 6,
      title = "This is a pull request",
      pull_request = { url = "https://api.github.com/example" },
    },
  })
  equal(#issues, 1, "Issues endpoint pull requests were not excluded")
  equal(issues[1].labels[2], "accessibility")

  local pulls = github.normalize_pulls({
    {
      id = 30,
      number = 7,
      title = "GitHub tabs",
      draft = true,
      user = { login = "octo" },
      head = { ref = "feature" },
      base = { ref = "bluff" },
      html_url = "https://github.com/octo/widgets/pull/7",
    },
  })
  equal(#pulls, 1)
  equal(pulls[1].head, "feature")
  equal(pulls[1].base, "bluff")
  assert(pulls[1].draft, "draft pull request lost its state")
end

local function test_transports_and_redaction()
  local repository = {
    host = "github.com",
    owner = "octo",
    name = "widgets",
    repository = "octo/widgets",
  }
  local token = "test_token_for_transport_redaction"
  local captured
  local result
  local client = github.new({
    transport = "gh",
    token_provider = function() return token end,
    executable = function(command) return command == "gh" end,
    schedule = function(callback) callback() end,
    defer = function() end,
    spawn = function(command, opts, callback)
      captured = { command = command, opts = opts }
      callback({
        code = 0,
        stdout = vim.json.encode({ workflow_runs = {
          { id = 1, name = "CI", status = "completed", conclusion = "success" },
        } }),
        stderr = "",
      })
      return {}
    end,
  })
  client:fetch("actions", repository, function(err, items, metadata)
    assert(not err, vim.inspect(err))
    result = { items = items, metadata = metadata }
  end)
  assert(result, "gh transport callback did not run")
  equal(result.metadata.transport, "gh")
  equal(#result.items, 1)
  equal(captured.opts.env.GH_TOKEN, token)
  assert(not table.concat(captured.command, " "):find(token, 1, true),
    "token leaked into gh command arguments")

  local curl_capture
  local curl_result
  local curl_client = github.new({
    transport = "curl",
    token_provider = function() return token end,
    executable = function(command) return command == "curl" end,
    schedule = function(callback) callback() end,
    defer = function() end,
    spawn = function(command, opts, callback)
      curl_capture = { command = command, opts = opts }
      callback({ code = 0, stdout = "[]\n200", stderr = "" })
      return {}
    end,
  })
  curl_client:fetch("issues", repository, function(err, items, metadata)
    assert(not err, vim.inspect(err))
    curl_result = { items = items, metadata = metadata }
  end)
  assert(curl_result, "curl transport callback did not run")
  equal(curl_result.metadata.transport, "curl")
  assert(not table.concat(curl_capture.command, " "):find(token, 1, true),
    "token leaked into curl command arguments")
  equal(curl_capture.command[2], "--disable", "curl user configuration was not disabled")
  assert(not vim.tbl_contains(curl_capture.command, "--location"),
    "curl transport follows credential-bearing redirects")
  contains(curl_capture.opts.stdin, "Authorization: Bearer " .. token)

  local custom_api_transport
  local custom_api_client = github.new({
    transport = "auto",
    api_url = "https://github-api.example.test",
    executable = function() return true end,
    schedule = function(callback) callback() end,
    defer = function() end,
    spawn = function(command, _, callback)
      custom_api_transport = command[1]
      callback({ code = 0, stdout = "[]\n200", stderr = "" })
      return {}
    end,
  })
  custom_api_client:fetch("pulls", repository, function(err)
    assert(not err, vim.inspect(err))
  end)
  equal(custom_api_transport, "curl", "custom API base did not select curl")

  local insecure_error
  github.new({
    transport = "curl",
    api_url = "http://github-api.example.test",
    executable = function() return true end,
    schedule = function(callback) callback() end,
    defer = function() end,
    spawn = function() error("insecure API request should not spawn curl") end,
  }):fetch("issues", repository, function(err) insecure_error = err end)
  equal(insecure_error.kind, "configuration")
  contains(insecure_error.message, "HTTPS")

  local auth_error
  local error_client = github.new({
    transport = "gh",
    token_provider = function() return token end,
    executable = function() return true end,
    schedule = function(callback) callback() end,
    defer = function() end,
    spawn = function(_, _, callback)
      callback({ code = 1, stdout = "", stderr = "gh: Bad credentials " .. token .. " (HTTP 401)" })
      return {}
    end,
  })
  error_client:fetch("actions", repository, function(err) auth_error = err end)
  equal(auth_error.kind, "authentication")
  assert(not auth_error.message:find(token, 1, true), "token leaked into authentication error")
  equal(github.redact("token=" .. token, { token }), "token=<redacted>")
end

local function test_help_rendering()
  local rendered = help.render({ width = 64 })
  local text = table.concat(rendered.lines, "\n")
  contains(text, "Navigate")
  contains(text, "GitHub views")
  contains(text, "Branches & worktrees")
  for _, line in ipairs(rendered.lines) do
    assert(vim.fn.strdisplaywidth(line) <= rendered.width,
      ("help line exceeds width %d: %s"):format(rendered.width, line))
  end
  assert(#rendered.highlights > 20, "help renderer did not emit semantic highlights")

  local buf, win = help.open({ max_width = 64, border = "rounded" })
  assert(vim.api.nvim_buf_is_valid(buf), "help buffer is invalid")
  assert(vim.api.nvim_win_is_valid(win), "help window is invalid")
  equal(vim.bo[buf].filetype, "gitpanelhelp")
  assert(vim.api.nvim_win_get_config(win).width <= 64, "help float ignored max_width")
  local namespace = vim.api.nvim_get_namespaces()["gitpanel-help"]
  local marks = vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {})
  assert(#marks > 20, "help float did not apply highlight extmarks")
  vim.api.nvim_win_close(win, true)
end

local function test_concurrent_local_snapshot()
  local callbacks, completed = {}, nil
  local_model.gather("/tmp/example", {
    system = function(command, opts, callback)
      callbacks[#callbacks + 1] = { command = command, opts = opts, callback = callback }
      return {}
    end,
  }, function(value) completed = value end)

  equal(#callbacks, 10, "local snapshot did not launch every independent read")
  assert(completed == nil, "local snapshot completed before command callbacks")
  for _, request in ipairs(callbacks) do
    equal(request.command[1], "git")
    equal(request.opts.cwd, "/tmp/example")
    request.callback({ code = 1, stdout = "", stderr = "fixture unavailable" })
  end
  assert(vim.wait(1000, function() return completed ~= nil end),
    "local snapshot did not join concurrent command callbacks")
  equal(#completed.errors, 1, "only the required status failure should surface")
end

local function test_pull_request_mutations()
  local repository = {
    host = "github.com",
    owner = "octo",
    name = "widgets",
    repository = "octo/widgets",
  }
  local token = "test_token_for_mutations"

  local function stub_client(transport, response)
    local capture = {}
    local client = github.new({
      transport = transport,
      token_provider = function() return token end,
      executable = function(command) return command == transport end,
      schedule = function(callback) callback() end,
      defer = function() end,
      spawn = function(command, opts, callback)
        capture.command, capture.opts = command, opts
        callback(response)
        return {}
      end,
    })
    return client, capture
  end

  -- merge over gh: method + endpoint + JSON body on stdin, never in argv
  local client, capture = stub_client("gh", {
    code = 0, stdout = vim.json.encode({ merged = true }), stderr = "",
  })
  local merged
  client:merge_pull(repository, 7, function(err, payload)
    assert(not err, vim.inspect(err))
    merged = payload
  end)
  assert(merged and merged.merged, "merge_pull callback did not deliver the payload")
  local rendered = table.concat(capture.command, " ")
  contains(rendered, "--method PUT")
  contains(rendered, "repos/octo/widgets/pulls/7/merge")
  contains(capture.opts.stdin, "merge_method")
  assert(not rendered:find(token, 1, true), "token leaked into gh mutation arguments")

  -- branch delete over curl: DELETE with an empty 204 body succeeds with nil data
  local curl_client, curl_capture = stub_client("curl", {
    code = 0, stdout = "\n204", stderr = "",
  })
  local deleted, delete_payload = false, "sentinel"
  curl_client:delete_branch(repository, "claude/workstation-topic", function(err, payload)
    assert(not err, vim.inspect(err))
    deleted, delete_payload = true, payload
  end)
  assert(deleted, "delete_branch callback did not run")
  assert(delete_payload == nil, "an empty 204 response should decode to nil")
  local curl_rendered = table.concat(curl_capture.command, " ")
  contains(curl_rendered, "--request DELETE")
  contains(curl_rendered, "git/refs/heads/claude/workstation-topic")
  contains(curl_capture.opts.stdin, "Authorization: Bearer " .. token)

  -- comment posts to the issues conversation endpoint
  local comment_client, comment_capture = stub_client("gh", {
    code = 0, stdout = vim.json.encode({ id = 1 }), stderr = "",
  })
  local commented
  comment_client:comment_pull(repository, 7, "applied: 19 ok", function(err)
    assert(not err, vim.inspect(err))
    commented = true
  end)
  assert(commented, "comment_pull callback did not run")
  contains(table.concat(comment_capture.command, " "), "repos/octo/widgets/issues/7/comments")
  contains(comment_capture.opts.stdin, "applied: 19 ok")

  -- guards fail closed without spawning anything
  local guard_client = github.new({
    transport = "gh",
    executable = function() return true end,
    schedule = function(callback) callback() end,
    defer = function() end,
    spawn = function() error("guarded mutation must not spawn") end,
  })
  local guard_errors = {}
  guard_client:delete_branch(repository, "../evil", function(err) guard_errors[#guard_errors + 1] = err end)
  guard_client:comment_pull(repository, 7, "   ", function(err) guard_errors[#guard_errors + 1] = err end)
  guard_client:merge_pull(repository, nil, function(err) guard_errors[#guard_errors + 1] = err end)
  equal(#guard_errors, 3, "unsafe mutations must be rejected before spawning")
  for _, err in ipairs(guard_errors) do
    equal(err.kind, "configuration")
  end
end

test_remote_parsing()
test_normalization()
test_transports_and_redaction()
test_pull_request_mutations()
test_help_rendering()
test_concurrent_local_snapshot()

print("GitPanel unit tests passed")
