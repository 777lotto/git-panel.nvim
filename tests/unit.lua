local github = require("git_panel.github")
local help = require("git_panel.help")
local local_model = require("git_panel.model")
local signed_merge = require("git_panel.signed_merge")

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
      head = {
        ref = "feature",
        sha = string.rep("a", 40),
        label = "octo:feature",
        repo = { full_name = "octo/widgets" },
      },
      base = {
        ref = "bluff",
        sha = string.rep("b", 40),
        repo = { full_name = "octo/widgets" },
      },
      html_url = "https://github.com/octo/widgets/pull/7",
    },
  })
  equal(#pulls, 1)
  equal(pulls[1].head, "feature")
  equal(pulls[1].head_sha, string.rep("a", 40))
  equal(pulls[1].head_label, "octo:feature")
  equal(pulls[1].head_repository, "octo/widgets")
  equal(pulls[1].base, "bluff")
  equal(pulls[1].base_repository, "octo/widgets")
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
  equal(captured.command[1], "gh")
  equal(captured.command[2], "api")
  equal(captured.command[3], "repos/octo/widgets/actions/runs?per_page=30")
  assert(not vim.tbl_contains(captured.command, "--hostname"),
    "gh-compatible wrappers must receive the endpoint before flags without a hostname override")
  equal(captured.opts.env.GH_HOST, "github.com")
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

local function test_signed_merge_backend()
  local base_sha = string.rep("a", 40)
  local head_sha = string.rep("b", 40)
  local merge_sha = string.rep("c", 40)
  local worktree = "/tmp/git-panel-signed-merge-fixture"

  local function fixture(overrides)
    overrides = overrides or {}
    local commands = {}
    local responses = {
      validate_base = { code = 0, stdout = "", stderr = "" },
      validate_head = { code = 0, stdout = "", stderr = "" },
      fetch_base = { code = 0, stdout = "", stderr = "" },
      resolve_base = { code = 0, stdout = base_sha .. "\n", stderr = "" },
      fetch_head = { code = 0, stdout = "", stderr = "" },
      resolve_head = { code = 0, stdout = (overrides.fetched_head or head_sha) .. "\n", stderr = "" },
      add_worktree = { code = 0, stdout = "", stderr = "" },
      merge = { code = 0, stdout = "", stderr = "" },
      resolve_merge = { code = 0, stdout = merge_sha .. "\n", stderr = "" },
      inspect_signature = {
        code = 0,
        stdout = overrides.commit or ("tree " .. string.rep("d", 40) .. "\n" ..
          "parent " .. base_sha .. "\nparent " .. head_sha .. "\n" ..
          "gpgsig -----BEGIN PGP SIGNATURE-----\n fixture\n\nmerge\n"),
        stderr = "",
      },
      inspect_parents = {
        code = 0,
        stdout = merge_sha .. " " .. base_sha .. " " .. head_sha .. "\n",
        stderr = "",
      },
      verify_base = { code = 0, stdout = "", stderr = "" },
      push_base = { code = 0, stdout = "ok\n", stderr = "" },
      delete_head = { code = 0, stdout = "ok\n", stderr = "" },
      cleanup = { code = 0, stdout = "", stderr = "" },
    }
    local function runner(args, cwd, stage)
      commands[#commands + 1] = { args = vim.deepcopy(args), cwd = cwd, stage = stage }
      return assert(responses[stage], "unexpected signed merge stage: " .. tostring(stage))
    end
    local result, err = signed_merge.run({
      root = "/tmp/repository",
      remote = "origin",
      repository = "octo/widgets",
      number = 7,
      title = "Signed Git backend",
      base = "bluff",
      head = "feature",
      head_sha = head_sha,
      head_label = "octo:feature",
      head_repository = overrides.head_repository or "octo/widgets",
    }, { run = runner, tempname = function() return worktree end })
    return result, err, commands
  end

  local function command_for(commands, stage)
    for _, command in ipairs(commands) do
      if command.stage == stage then return command end
    end
    return nil
  end

  local result, err, commands = fixture()
  assert(result and not err, vim.inspect(err))
  equal(result.merge_sha, merge_sha)
  assert(result.remote_branch_deleted, "same-repository head branch was not deleted")
  local merge = assert(command_for(commands, "merge"))
  equal(merge.cwd, worktree)
  assert(vim.tbl_contains(merge.args, "--gpg-sign"), "signed_git did not require a signature")
  assert(vim.tbl_contains(merge.args, "--no-ff"), "signed_git did not force a merge commit")
  local push = assert(command_for(commands, "push_base"))
  assert(not table.concat(push.args, " "):find("force", 1, true),
    "signed merge base push must not force-update the base branch")
  contains(table.concat(push.args, " "), merge_sha .. ":refs/heads/bluff")
  local deletion = assert(command_for(commands, "delete_head"))
  contains(table.concat(deletion.args, " "),
    "--force-with-lease=refs/heads/feature:" .. head_sha)
  assert(command_for(commands, "cleanup"), "temporary worktree was not removed")

  local cross_result, cross_error, cross_commands = fixture({ head_repository = "fork/widgets" })
  assert(cross_result and not cross_error, vim.inspect(cross_error))
  assert(not cross_result.head_is_local and not cross_result.remote_branch_deleted,
    "cross-repository head was treated as a local branch")
  assert(not command_for(cross_commands, "delete_head"),
    "signed_git attempted to delete a cross-repository head branch")

  local stale_result, stale_error, stale_commands = fixture({ fetched_head = string.rep("e", 40) })
  assert(not stale_result and stale_error.kind == "stale", "changed pull request head was not rejected")
  assert(not command_for(stale_commands, "add_worktree"),
    "stale pull request created a merge worktree")

  local unsigned_result, unsigned_error, unsigned_commands = fixture({
    commit = "tree " .. string.rep("d", 40) .. "\nparent " .. base_sha ..
      "\nparent " .. head_sha .. "\n\nunsigned\n",
  })
  assert(not unsigned_result and unsigned_error.kind == "signing",
    "unsigned merge commit was accepted")
  assert(command_for(unsigned_commands, "cleanup"),
    "unsigned merge did not clean its temporary worktree")
  assert(not command_for(unsigned_commands, "push_base"),
    "unsigned merge commit reached the push stage")
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
  local reviewed_head = string.rep("a", 40)
  client:merge_pull(repository, 7, reviewed_head, function(err, payload)
    assert(not err, vim.inspect(err))
    merged = payload
  end)
  assert(merged and merged.merged, "merge_pull callback did not deliver the payload")
  local rendered = table.concat(capture.command, " ")
  contains(rendered, "--method PUT")
  contains(rendered, "repos/octo/widgets/pulls/7/merge")
  contains(capture.opts.stdin, "merge_method")
  contains(capture.opts.stdin, reviewed_head)
  assert(not rendered:find(token, 1, true), "token leaked into gh mutation arguments")

  local refused_client = stub_client("gh", {
    code = 0, stdout = vim.json.encode({ merged = false, message = "Base branch changed" }), stderr = "",
  })
  local refused_error
  refused_client:merge_pull(repository, 7, reviewed_head, function(err) refused_error = err end)
  equal(refused_error.kind, "merge", "an unconfirmed API merge was treated as successful")
  contains(refused_error.message, "Base branch changed")

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
  guard_client:merge_pull(repository, 7, "not-a-sha", function(err) guard_errors[#guard_errors + 1] = err end)
  equal(#guard_errors, 4, "unsafe mutations must be rejected before spawning")
  for _, err in ipairs(guard_errors) do
    equal(err.kind, "configuration")
  end
end

-- A GitHub-compatible proxy mounts repositories under a path prefix and may
-- expose a plaintext REST base on a private network. Both are opt-in and must
-- not change discovery or transport behaviour for github.com users.
local function test_proxied_github_host()
  local proxy = {
    host = "proxy.example:8790",
    api_url = "http://proxy.example:8790/github/api",
    remote_path_prefix = "github/git",
    allow_insecure_http = true,
  }

  local prefixed = assert(github.parse_remote(
    "http://proxy.example:8790/github/git/octo/widgets.nvim.git", proxy))
  equal(prefixed.host, "proxy.example:8790")
  equal(prefixed.repository, "octo/widgets.nvim")
  equal(github.api_base(prefixed, proxy), "http://proxy.example:8790/github/api")

  -- a list of prefixes is accepted, and the prefix is only stripped when present
  local listed = assert(github.parse_remote(
    "ssh://git@proxy.example/mirror/octo/widgets.nvim.git",
    { remote_path_prefix = { "github/git", "mirror" } }))
  equal(listed.repository, "octo/widgets.nvim")
  assert(github.parse_remote("https://github.com/octo/nested/widgets.nvim", proxy) == nil,
    "an unprefixed nested path must not be read as OWNER/REPO")
  local cloud = assert(github.parse_remote("git@github.com:octo/widgets.nvim.git", proxy))
  equal(cloud.host, "github.com", "proxy settings must not disturb github.com remotes")

  local function client_error(opts)
    opts = vim.tbl_extend("force", { transport = "curl", root = ".",
      executable = function() return true end,
      schedule = function(callback) callback() end,
      defer = function() end,
      spawn = function(_, spawn_opts, callback)
        callback({ code = 0, stdout = "{}\n200", stderr = "", stdin = spawn_opts.stdin })
        return {}
      end,
    }, opts)
    local captured, failure
    local spawn = opts.spawn
    opts.spawn = function(command, spawn_opts, callback)
      captured = spawn_opts.stdin or ""
      return spawn(command, spawn_opts, callback)
    end
    github.new(opts):fetch("overview", prefixed, function(err) failure = err end)
    return failure, captured
  end

  local without_optin = client_error({ api_url = "http://proxy.example:8790/github/api" })
  equal(without_optin.kind, "configuration", "plaintext must stay opt-in")
  contains(without_optin.message, "allow_insecure_http")

  local anonymous, anonymous_config = client_error({
    api_url = "http://proxy.example:8790/github/api", allow_insecure_http = true })
  assert(not anonymous, vim.inspect(anonymous))
  assert(not anonymous_config:find("Authorization", 1, true),
    "an anonymous proxy request must not send an Authorization header")

  -- a credential must never cross a plaintext hop that leaves the machine
  local leaked = client_error({
    api_url = "http://proxy.example:8790/github/api",
    allow_insecure_http = true,
    token_provider = function() return "ghp_examplevalue" end,
  })
  equal(leaked.kind, "configuration")
  contains(leaked.message, "plaintext")
  assert(not leaked.message:find("ghp_examplevalue", 1, true), "token leaked into an error")

  local loopback, loopback_config = client_error({
    api_url = "http://127.0.0.1:8790/api/v3",
    allow_insecure_http = true,
    token_provider = function() return "ghp_examplevalue" end,
  })
  assert(not loopback, vim.inspect(loopback))
  contains(loopback_config, "Authorization", "loopback stays trusted for tokens")
end

test_remote_parsing()
test_proxied_github_host()
test_normalization()
test_transports_and_redaction()
test_pull_request_mutations()
test_signed_merge_backend()
test_help_rendering()
test_concurrent_local_snapshot()

print("GitPanel unit tests passed")
