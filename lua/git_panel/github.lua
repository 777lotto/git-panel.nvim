local fn = vim.fn

local M = {}
local Client = {}
Client.__index = Client

local TOKEN_PATTERNS = {
  'github_pat_[%w_%.%-]+',
  'gh[pousr]_[%w_%.%-]+',
}

local function trim(value)
  return (value or ''):match('^%s*(.-)%s*$')
end

local function strip_nil(value)
  if value == vim.NIL then return nil end
  return value
end

local function host_without_port(host)
  return (host or ''):gsub(':%d+$', ''):lower()
end

local function is_cloud_host(host)
  host = host_without_port(host)
  return host == 'github.com' or host:match('%.ghe%.com$') ~= nil
end

local function is_supported_host(host, configured_host)
  local normalized = host_without_port(host)
  if normalized == 'github.com' or normalized:match('%.ghe%.com$') then return true end
  return configured_host ~= nil and normalized == host_without_port(configured_host)
end

local function validate_repository(owner, name)
  local safe = '^[%w_.-]+$'
  return owner and name and owner:match(safe) and name:match(safe)
end

local function valid_api_url(value)
  return value:match('^https://[^/%s]+[^%s]*$') ~= nil
    and value:find('[%c?#]') == nil
end

local function api_version(opts)
  local value = opts.api_version or '2026-03-10'
  if type(value) ~= 'string' or not value:match('^%d%d%d%d%-%d%d%-%d%d$') then
    return nil, 'github.api_version must use YYYY-MM-DD format'
  end
  return value
end

function M.parse_remote(remote_url)
  local value = trim(remote_url)
  if value == '' then return nil end

  local host, path
  local authority, url_path = value:match('^%a[%w+.-]*://([^/]+)/(.+)$')
  if authority then
    authority = authority:match('@(.+)$') or authority
    host, path = authority, url_path
  else
    host, path = value:match('^[^@/]+@([^:]+):(.+)$')
  end
  if not host or not path then return nil end

  path = path:gsub('[?#].*$', ''):gsub('^/+', ''):gsub('/+$', ''):gsub('%.git$', '')
  local owner, name = path:match('^([^/]+)/([^/]+)$')
  if not validate_repository(owner, name) then return nil end
  if host_without_port(host) == 'ssh.github.com' then host = 'github.com' end

  return {
    host = host:lower(),
    owner = owner,
    name = name,
    repository = owner .. '/' .. name,
    remote_url = value,
  }
end

local function configured_repository(opts)
  local configured = trim(opts.repository)
  if configured == '' then return nil end

  local parsed = M.parse_remote(configured)
  if parsed then
    if opts.host and host_without_port(opts.host) ~= host_without_port(parsed.host) then
      return nil, 'github.host does not match github.repository URL'
    end
    return parsed
  end

  local owner, name = configured:match('^([^/]+)/([^/]+)$')
  if not validate_repository(owner, name) then
    return nil, 'github.repository must be OWNER/REPO or a GitHub remote URL'
  end
  return {
    host = trim(opts.host) ~= '' and trim(opts.host):lower() or 'github.com',
    owner = owner,
    name = name,
    repository = owner .. '/' .. name,
  }
end

function M.resolve_repository(root, opts)
  opts = opts or {}
  if opts.repository then return configured_repository(opts) end

  local result = vim.system({ 'git', 'config', '--get-regexp', '^remote\\..*\\.url$' }, {
    cwd = root,
    text = true,
    env = { LC_ALL = 'C', GIT_OPTIONAL_LOCKS = '0' },
  }):wait()
  if result.code ~= 0 then
    return nil, 'no Git remotes are configured'
  end

  local candidates = {}
  for line in (result.stdout or ''):gmatch('[^\r\n]+') do
    local name, remote_url = line:match('^remote%.([^%.]+)%.url%s+(.+)$')
    local parsed = M.parse_remote(remote_url)
    if name and parsed and is_supported_host(parsed.host, opts.host) then
      parsed.remote = name
      candidates[#candidates + 1] = parsed
    end
  end
  table.sort(candidates, function(left, right)
    if left.remote == 'origin' then return right.remote ~= 'origin' end
    if right.remote == 'origin' then return false end
    return left.remote < right.remote
  end)

  if #candidates == 0 then
    local suffix = opts.host and (' for host ' .. opts.host) or ''
    return nil, 'no GitHub remote detected' .. suffix
  end
  return candidates[1]
end

function M.api_base(repository, opts)
  opts = opts or {}
  local configured = trim(opts.api_url)
  if configured ~= '' then return configured:gsub('/+$', '') end

  local host = repository.host
  local normalized = host_without_port(host)
  if normalized == 'github.com' then return 'https://api.github.com' end
  if normalized:match('%.ghe%.com$') then return 'https://api.' .. host end
  return 'https://' .. host .. '/api/v3'
end

function M.redact(value, secrets)
  local text = tostring(value or '')
  for _, secret in ipairs(secrets or {}) do
    if secret and secret ~= '' then
      text = text:gsub(secret:gsub('([^%w])', '%%%1'), '<redacted>')
    end
  end
  for _, pattern in ipairs(TOKEN_PATTERNS) do
    text = text:gsub(pattern, '<redacted>')
  end
  return text
end

local function classify_error(status, text, transport, secrets)
  local safe = M.redact(text, secrets)
  safe = trim(safe:gsub('%c', ' '):gsub('%s+', ' '))
  if #safe > 500 then safe = safe:sub(1, 499) .. '…' end
  local lower = safe:lower()
  local kind, message = 'request', safe

  status = status or tonumber(lower:match('http%s+(%d%d%d)'))
  if status == 401 or lower:find('bad credentials', 1, true)
      or lower:find('authentication required', 1, true) then
    kind = 'authentication'
    message = 'GitHub authentication failed. Authenticate gh or configure github.token_provider.'
  elseif status == 403 and (lower:find('rate limit', 1, true) or lower:find('rate_limit', 1, true)) then
    kind = 'rate_limit'
    message = 'GitHub API rate limit reached. Authenticate or wait for the limit to reset.'
  elseif status == 403 then
    kind = 'permission'
    message = 'GitHub denied this request. Check repository access and read permissions.'
  elseif status == 404 then
    kind = 'not_found'
    message = 'GitHub repository not found, or the credential cannot access it.'
  elseif lower:find('could not resolve host', 1, true)
      or lower:find('connection refused', 1, true)
      or lower:find('timed out', 1, true) then
    kind = 'network'
    message = 'GitHub could not be reached. Check the network and configured host.'
  elseif safe == '' then
    message = 'GitHub request failed without an error message.'
  end

  return {
    kind = kind,
    message = message,
    status = status,
    transport = transport,
  }
end

local function decode_json(text, transport, secrets)
  local ok, decoded = pcall(vim.json.decode, text or '')
  if not ok then
    return nil, {
      kind = 'decode',
      message = 'GitHub returned invalid JSON: ' .. M.redact(decoded, secrets),
      transport = transport,
    }
  end
  return decoded
end

local function labels_from(raw)
  local labels = {}
  for _, label in ipairs(type(raw) == 'table' and raw or {}) do
    if type(label) == 'string' then
      labels[#labels + 1] = label
    elseif type(label) == 'table' and strip_nil(label.name) then
      labels[#labels + 1] = label.name
    end
  end
  return labels
end

function M.normalize_actions(payload)
  local items = {}
  local runs = type(payload) == 'table' and payload.workflow_runs or nil
  for _, run in ipairs(type(runs) == 'table' and runs or {}) do
    items[#items + 1] = {
      kind = 'action',
      id = tostring(run.id or ''),
      number = run.run_number,
      name = strip_nil(run.name) or strip_nil(run.workflow_name) or 'Workflow',
      title = strip_nil(run.display_title) or strip_nil(run.name) or 'Workflow run',
      status = strip_nil(run.status),
      conclusion = strip_nil(run.conclusion),
      event = strip_nil(run.event),
      branch = strip_nil(run.head_branch),
      sha = strip_nil(run.head_sha),
      actor = type(run.actor) == 'table' and strip_nil(run.actor.login) or nil,
      created_at = strip_nil(run.created_at),
      updated_at = strip_nil(run.updated_at),
      url = strip_nil(run.html_url),
    }
  end
  return items
end

function M.normalize_issues(payload)
  local items = {}
  for _, issue in ipairs(type(payload) == 'table' and payload or {}) do
    if strip_nil(issue.pull_request) == nil then
      items[#items + 1] = {
        kind = 'issue',
        id = tostring(issue.id or ''),
        number = issue.number,
        title = strip_nil(issue.title) or '(untitled issue)',
        state = strip_nil(issue.state),
        author = type(issue.user) == 'table' and strip_nil(issue.user.login) or nil,
        labels = labels_from(issue.labels),
        comments = issue.comments or 0,
        created_at = strip_nil(issue.created_at),
        updated_at = strip_nil(issue.updated_at),
        body = strip_nil(issue.body),
        url = strip_nil(issue.html_url),
      }
    end
  end
  return items
end

function M.normalize_pulls(payload)
  local items = {}
  for _, pull in ipairs(type(payload) == 'table' and payload or {}) do
    items[#items + 1] = {
      kind = 'pull',
      id = tostring(pull.id or ''),
      number = pull.number,
      title = strip_nil(pull.title) or '(untitled pull request)',
      state = strip_nil(pull.state),
      draft = strip_nil(pull.draft) == true,
      author = type(pull.user) == 'table' and strip_nil(pull.user.login) or nil,
      head = type(pull.head) == 'table' and strip_nil(pull.head.ref) or nil,
      base = type(pull.base) == 'table' and strip_nil(pull.base.ref) or nil,
      labels = labels_from(pull.labels),
      comments = (pull.comments or 0) + (pull.review_comments or 0),
      created_at = strip_nil(pull.created_at),
      updated_at = strip_nil(pull.updated_at),
      body = strip_nil(pull.body),
      url = strip_nil(pull.html_url),
    }
  end
  return items
end

local NORMALIZERS = {
  actions = M.normalize_actions,
  issues = M.normalize_issues,
  pulls = M.normalize_pulls,
}

local function endpoint_for(view, repository, per_page)
  local prefix = 'repos/' .. repository.repository
  if view == 'actions' then
    return prefix .. '/actions/runs?per_page=' .. per_page
  elseif view == 'issues' then
    return prefix .. '/issues?state=open&sort=updated&direction=desc&per_page=' .. per_page
  elseif view == 'pulls' then
    return prefix .. '/pulls?state=open&sort=updated&direction=desc&per_page=' .. per_page
  end
  return nil
end

local function default_spawn(command, opts, callback)
  return vim.system(command, opts, callback)
end

function Client.new(opts)
  opts = opts or {}
  return setmetatable({
    opts = opts,
    spawn = opts.spawn or default_spawn,
    executable = opts.executable or function(command) return fn.executable(command) == 1 end,
    schedule = opts.schedule or vim.schedule,
    defer = opts.defer or vim.defer_fn,
  }, Client)
end

function Client:_with_token(repository, callback)
  local provider = self.opts.token_provider
  if not provider then return callback(nil, nil) end

  local settled = false
  local function finish(token, err)
    if settled then return end
    settled = true
    if token ~= nil and type(token) ~= 'string' then
      return callback(nil, 'github.token_provider must return a token string')
    end
    token = token and trim(token) or nil
    if token == '' then token = nil end
    if token and not token:match('^[%w_.%-]+$') then
      return callback(nil, 'github.token_provider returned an unsafe token value')
    end
    callback(token, err)
  end

  local context = {
    host = repository.host,
    owner = repository.owner,
    name = repository.name,
    repository = repository.repository,
  }
  local ok, result, result_err = pcall(provider, context, finish)
  if not ok then return finish(nil, M.redact(result)) end
  if type(result) == 'string' then
    finish(result, result_err)
  elseif type(result) == 'table' and type(result.token) == 'string' then
    finish(result.token, result.error)
  elseif result == false then
    finish(nil, result_err or 'github.token_provider failed')
  elseif result ~= nil and result ~= true then
    finish(nil, 'github.token_provider returned an unsupported value')
  end

  if not settled then
    self.defer(function()
      finish(nil, 'github.token_provider timed out')
    end, self.opts.timeout or 15000)
  end
end

function Client:_spawn(command, opts, callback)
  local ok, job_or_error = pcall(self.spawn, command, opts, function(result)
    self.schedule(function() callback(result) end)
  end)
  if not ok then
    self.schedule(function()
      callback({ code = -1, stdout = '', stderr = tostring(job_or_error) })
    end)
  end
  return ok and job_or_error or nil
end

function Client:_request_gh(repository, spec, token, callback)
  local version, version_error = api_version(self.opts)
  if not version then
    return callback({ kind = 'configuration', message = version_error })
  end
  local command = {
    self.opts.gh_command or 'gh', 'api', '--hostname', repository.host,
    '--header', 'Accept: application/vnd.github+json',
    '--header', 'X-GitHub-Api-Version: ' .. version,
  }
  if spec.method and spec.method ~= 'GET' then
    command[#command + 1] = '--method'
    command[#command + 1] = spec.method
  end
  local stdin
  if spec.body ~= nil then
    command[#command + 1] = '--input'
    command[#command + 1] = '-'
    stdin = vim.json.encode(spec.body)
  end
  command[#command + 1] = spec.endpoint
  local env = {}
  if token then
    if is_cloud_host(repository.host) then env.GH_TOKEN = token
    else env.GH_ENTERPRISE_TOKEN = token end
  end

  self:_spawn(command, { text = true, cwd = self.opts.root, env = env, stdin = stdin,
    timeout = self.opts.timeout or 15000 }, function(result)
    if result.code ~= 0 then
      local detail = trim((result.stderr or '') ~= '' and result.stderr or result.stdout)
      return callback(classify_error(nil, detail, 'gh', { token }))
    end
    if trim(result.stdout) == '' then return callback(nil, nil) end
    local decoded, decode_error = decode_json(result.stdout, 'gh', { token })
    callback(decode_error, decoded)
  end)
end

function Client:_request_curl(repository, spec, token, callback)
  local version, version_error = api_version(self.opts)
  if not version then
    return callback({ kind = 'configuration', message = version_error })
  end
  local base_url = M.api_base(repository, self.opts)
  if not valid_api_url(base_url) then
    return callback({
      kind = 'configuration',
      message = 'github.api_url must be an HTTPS REST base without a query or fragment.',
    })
  end
  local url = base_url .. '/' .. spec.endpoint
  local config = {
    'header = "Accept: application/vnd.github+json"',
    'header = "X-GitHub-Api-Version: ' .. version .. '"',
  }
  if token then config[#config + 1] = 'header = "Authorization: Bearer ' .. token .. '"' end
  local timeout = tonumber(self.opts.timeout) or 15000
  local timeout_seconds = math.max(1, math.ceil(timeout / 1000))
  local command = {
    self.opts.curl_command or 'curl', '--disable', '--silent', '--show-error',
    '--config', '-', '--max-time', tostring(timeout_seconds),
    '--write-out', '\n%{http_code}', '--url', url,
  }
  if spec.method and spec.method ~= 'GET' then
    command[#command + 1] = '--request'
    command[#command + 1] = spec.method
  end
  if spec.body ~= nil then
    -- The body is never a secret (titles, comments, branch names); only the
    -- Authorization header is, and that stays on the stdin config channel.
    command[#command + 1] = '--data'
    command[#command + 1] = vim.json.encode(spec.body)
    command[#command + 1] = '--header'
    command[#command + 1] = 'Content-Type: application/json'
  end

  self:_spawn(command, { text = true, cwd = self.opts.root,
    stdin = table.concat(config, '\n') .. '\n', timeout = timeout }, function(result)
    if result.code ~= 0 then
      return callback(classify_error(nil, trim(result.stderr), 'curl', { token }))
    end
    local body, status_text = (result.stdout or ''):match('^(.*)\n(%d%d%d)$')
    local status = tonumber(status_text)
    if not body or not status then
      return callback(classify_error(nil, 'curl returned an invalid HTTP response', 'curl', { token }))
    end
    if status < 200 or status >= 300 then
      return callback(classify_error(status, body, 'curl', { token }))
    end
    if trim(body) == '' then return callback(nil, nil) end
    local decoded, decode_error = decode_json(body, 'curl', { token })
    callback(decode_error, decoded)
  end)
end

function Client:_dispatch(spec, repository, callback)
  self:_with_token(repository, function(token, token_error)
    if token_error then
      return callback({ kind = 'authentication', message = M.redact(token_error, { token }) })
    end

    local requested = self.opts.transport or 'auto'
    local custom_api = trim(self.opts.api_url) ~= ''
    if requested == 'gh' and custom_api then
      return callback({
        kind = 'configuration',
        message = 'github.api_url requires the curl transport.',
      })
    end
    local transports = {}
    local gh_command = self.opts.gh_command or 'gh'
    local curl_command = self.opts.curl_command or 'curl'
    if not custom_api and (requested == 'auto' or requested == 'gh') and self.executable(gh_command) then
      transports[#transports + 1] = 'gh'
    end
    if (requested == 'auto' or requested == 'curl') and self.executable(curl_command) then
      transports[#transports + 1] = 'curl'
    end
    if #transports == 0 then
      return callback({
        kind = 'transport',
        message = 'GitHub views need an authenticated gh CLI or curl (public repos may use curl anonymously).',
      })
    end

    local index, last_error = 1, nil
    local function attempt()
      local transport = transports[index]
      local request = transport == 'gh' and self._request_gh or self._request_curl
      request(self, repository, spec, token, function(err, payload)
        if err then
          last_error = err
          index = index + 1
          if index <= #transports then return attempt() end
          return callback(last_error)
        end
        callback(nil, payload, { transport = transport })
      end)
    end
    attempt()
  end)
end

function Client:fetch(view, repository, callback)
  local per_page = math.max(1, math.min(100, math.floor(tonumber(self.opts.per_page) or 30)))
  local endpoint = endpoint_for(view, repository, per_page)
  local normalize = NORMALIZERS[view]
  if not endpoint or not normalize then
    return callback({ kind = 'configuration', message = 'Unknown GitHub view: ' .. tostring(view) })
  end

  self:_dispatch({ endpoint = endpoint }, repository, function(err, payload, meta)
    if err then return callback(err) end
    local ok, items = pcall(normalize, payload)
    if not ok then
      return callback({ kind = 'decode', message = 'Could not normalize GitHub response: ' .. M.redact(items) })
    end
    callback(nil, items, meta)
  end)
end

-- ---- write operations (pull-request actions) ---------------------------------
-- Every mutation is a REST call through the same transport chain as fetch;
-- callers confirm with the user BEFORE reaching this layer.

local MUTATION_METHODS = { POST = true, PUT = true, PATCH = true, DELETE = true }

function Client:mutate(spec, repository, callback)
  if not MUTATION_METHODS[spec.method or ''] then
    return callback({ kind = 'configuration', message = 'Unsupported mutation method: ' .. tostring(spec.method) })
  end
  self:_dispatch(spec, repository, callback)
end

local function valid_pull_number(number)
  return type(number) == 'number' and number > 0 and number == math.floor(number)
end

function Client:merge_pull(repository, number, callback)
  if not valid_pull_number(number) then
    return callback({ kind = 'configuration', message = 'merge_pull needs a pull request number' })
  end
  self:mutate({
    method = 'PUT',
    endpoint = 'repos/' .. repository.repository .. '/pulls/' .. number .. '/merge',
    body = { merge_method = 'merge' },
  }, repository, callback)
end

function Client:comment_pull(repository, number, body, callback)
  if not valid_pull_number(number) then
    return callback({ kind = 'configuration', message = 'comment_pull needs a pull request number' })
  end
  if trim(body) == '' then
    return callback({ kind = 'configuration', message = 'comment_pull refuses an empty comment' })
  end
  self:mutate({
    method = 'POST',
    -- PR conversation comments live on the issues endpoint (review comments differ).
    endpoint = 'repos/' .. repository.repository .. '/issues/' .. number .. '/comments',
    body = { body = body },
  }, repository, callback)
end

function Client:delete_branch(repository, branch, callback)
  branch = trim(branch)
  if branch == '' or branch:find('%.%.') or not branch:match('^[%w][%w/_.%-]*$') then
    return callback({ kind = 'configuration', message = 'delete_branch refuses unsafe branch name' })
  end
  self:mutate({
    method = 'DELETE',
    endpoint = 'repos/' .. repository.repository .. '/git/refs/heads/' .. branch,
  }, repository, callback)
end

M.Client = Client
M.new = Client.new

return M
