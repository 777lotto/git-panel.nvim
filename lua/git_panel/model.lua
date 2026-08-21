-- Asynchronous local Git snapshot used by the dashboard renderer.
-- Every command is argv-only, repository-scoped, and independent commands run
-- concurrently so a rich dashboard does not turn into a serial startup tax.
local uv = vim.uv or vim.loop

local M = {}

local function chomp(value)
  local trimmed = (value or ''):gsub('%s+$', '')
  return trimmed
end

local function nul_split(value)
  local fields = {}
  for field in (value or ''):gmatch('([^%z]*)%z') do fields[#fields + 1] = field end
  return fields
end

local function realpath(path)
  return (path and uv.fs_realpath(path)) or path
end

local function same_path(left, right)
  left, right = realpath(left), realpath(right)
  if not left or not right then return false end
  if uv.os_uname().sysname == 'Darwin' then
    return left:lower() == right:lower()
  end
  return left == right
end

local function parse_status(model, output)
  local tokens = nul_split(output)
  local index = 1
  while index <= #tokens do
    local token = tokens[index]
    if token:sub(1, 2) == '# ' then
      local key, value = token:match('^# branch%.(%S+)%s+(.+)$')
      if key == 'oid' then
        if value == '(initial)' then
          model.head.unborn = true
        else
          model.head.oid = value
          model.head.sha = value:sub(1, 7)
        end
      elseif key == 'head' then
        if value == '(detached)' then model.head.detached = true
        else model.head.branch = value end
      elseif key == 'upstream' then
        model.head.upstream = value
      elseif key == 'ab' then
        local ahead, behind = value:match('^%+(%d+)%s+%-(%d+)$')
        model.head.ahead = tonumber(ahead) or 0
        model.head.behind = tonumber(behind) or 0
      end
      index = index + 1
    else
      local kind = token:sub(1, 1)
      if kind == '1' then
        local xy = token:sub(3, 4)
        local path = token:match('^%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+(.+)$')
        local record = { x = xy:sub(1, 1), y = xy:sub(2, 2), path = path }
        if record.x ~= '.' then model.staged[#model.staged + 1] = record end
        if record.y ~= '.' then model.unstaged[#model.unstaged + 1] = record end
        index = index + 1
      elseif kind == '2' then
        local xy = token:sub(3, 4)
        local path = token:match('^%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+(.+)$')
        local record = {
          x = xy:sub(1, 1), y = xy:sub(2, 2), path = path, orig = tokens[index + 1],
        }
        if record.x ~= '.' then model.staged[#model.staged + 1] = record end
        if record.y ~= '.' then model.unstaged[#model.unstaged + 1] = record end
        index = index + 2
      elseif kind == 'u' then
        local xy = token:sub(3, 4)
        local path = token:match('^u%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+(.+)$')
        model.conflicts[#model.conflicts + 1] = {
          x = xy:sub(1, 1), y = xy:sub(2, 2), path = path,
        }
        index = index + 1
      elseif kind == '?' then
        model.untracked[#model.untracked + 1] = { path = token:sub(3) }
        index = index + 1
      else
        index = index + 1
      end
    end
  end
end

local function parse_refs(model, output)
  for line in chomp(output):gmatch('[^\n]+') do
    local fields = {}
    for field in (line .. '\0'):gmatch('([^%z]*)%z') do fields[#fields + 1] = field end
    local refname = fields[1] or ''
    if refname:match('^refs/heads/') and fields[3] and fields[3] ~= '' then
      model.branches[#model.branches + 1] = {
        current = fields[2] == '*',
        name = fields[3],
        sha = fields[4],
        upstream = fields[5] ~= '' and fields[5] or nil,
        remote = fields[6] ~= '' and fields[6] or nil,
        remote_ref = fields[7] ~= '' and fields[7] or nil,
        track = fields[8] or '',
        worktree = fields[9] ~= '' and fields[9] or nil,
        author = fields[10] ~= '' and fields[10] or nil,
        timestamp = tonumber(fields[11]),
        subject = fields[12] or '',
      }
    elseif refname:match('^refs/tags/') and fields[3] and fields[3] ~= '' then
      model.tags[#model.tags + 1] = {
        name = fields[3], sha = fields[4], timestamp = tonumber(fields[11]),
        subject = fields[12] or '',
      }
    end
  end
  for index, branch in ipairs(model.branches) do
    if branch.current then
      table.remove(model.branches, index)
      table.insert(model.branches, 1, branch)
      break
    end
  end
end

local function parse_worktrees(model, output, root)
  local current = {}
  local function flush()
    if current.path then
      local label = '(bare)'
      if current.branch then label = current.branch:gsub('^refs/heads/', '')
      elseif current.detached and current.HEAD then
        label = current.HEAD:sub(1, 7) .. ' (detached)'
      end
      model.worktrees[#model.worktrees + 1] = {
        path = current.path,
        label = label,
        current = same_path(current.path, root),
        flags = {
          locked = current.locked, prunable = current.prunable, bare = current.bare,
        },
      }
    end
    current = {}
  end
  for _, token in ipairs(nul_split(output)) do
    if token == '' then
      flush()
    else
      local key, value = token:match('^(%S+)%s?(.*)$')
      if key == 'worktree' then current.path = value
      elseif key == 'HEAD' then current.HEAD = value
      elseif key == 'branch' then current.branch = value
      elseif key == 'bare' then current.bare = true
      elseif key == 'detached' then current.detached = true
      elseif key == 'locked' then current.locked = true
      elseif key == 'prunable' then current.prunable = true end
    end
  end
  flush()
end

local function parse_commits(target, output, limit)
  local tokens = nul_split(output)
  for index = 1, #tokens - 5, 6 do
    target[#target + 1] = {
      sha = tokens[index],
      sig = tokens[index + 1],
      author = tokens[index + 2],
      timestamp = tonumber(tokens[index + 3]),
      subject = tokens[index + 4],
      refs = tokens[index + 5],
    }
    if limit and #target >= limit then break end
  end
end

local function parse_pushes(model, output)
  local tokens = nul_split(output)
  local entries = {}
  for index = 1, #tokens - 4, 5 do
    entries[#entries + 1] = {
      new = tokens[index],
      short = tokens[index + 1],
      date = (tokens[index + 2]:match('@{(.-)}$') or ''),
      reflog = tokens[index + 3],
      subject = tokens[index + 4],
    }
  end
  for index, entry in ipairs(entries) do
    entry.old = entries[index + 1] and entries[index + 1].new or nil
    if (entry.reflog or ''):lower():find('push', 1, true) then
      model.pushes[#model.pushes + 1] = entry
    end
  end
end

local function parse_stashes(model, output)
  local tokens = nul_split(output)
  for index = 1, #tokens - 3, 4 do
    model.stashes[#model.stashes + 1] = {
      name = tokens[index], sha = tokens[index + 1],
      timestamp = tonumber(tokens[index + 2]), subject = tokens[index + 3],
    }
  end
end

local function parse_remotes(model, output)
  local by_name = {}
  for line in (output or ''):gmatch('[^\r\n]+') do
    local name, url, direction = line:match('^(%S+)%s+(%S+)%s+%((%a+)%)$')
    if name and url and direction then
      if not by_name[name] then
        by_name[name] = { name = name }
        model.remotes[#model.remotes + 1] = name
        model.remote_details[#model.remote_details + 1] = by_name[name]
      end
      by_name[name][direction .. '_url'] = url
    end
  end
  table.sort(model.remotes)
  table.sort(model.remote_details, function(left, right) return left.name < right.name end)
end

local function finalize(model)
  if #model.remotes == 0 then model.unpushed = {} end

  local seen = {}
  local function add_uncommitted(record, badge)
    if not record.path or seen[record.path] then return end
    seen[record.path] = true
    model.uncommitted[#model.uncommitted + 1] = {
      x = record.x, y = record.y, path = record.path, orig = record.orig, badge = badge,
    }
  end
  for _, record in ipairs(model.conflicts) do add_uncommitted(record, 'conflict') end
  for _, record in ipairs(model.staged) do add_uncommitted(record) end
  for _, record in ipairs(model.unstaged) do add_uncommitted(record) end
  for _, record in ipairs(model.untracked) do
    add_uncommitted({ x = '?', y = '?', path = record.path }, 'untracked')
  end

  model.has_remotes = #model.remotes > 0
  model.working_clean = #model.staged == 0 and #model.unstaged == 0
    and #model.untracked == 0 and #model.conflicts == 0
  model.synced = model.head.upstream ~= nil
    and (model.head.ahead or 0) == 0 and (model.head.behind or 0) == 0
  model.latest = model.commits[1]
  return model
end

function M.gather(root, opts, callback)
  opts = opts or {}
  local model = {
    branches = {}, worktrees = {}, staged = {}, unstaged = {}, untracked = {},
    conflicts = {}, commits = {}, uncommitted = {}, unpushed = {}, pushes = {},
    stashes = {}, tags = {}, remotes = {}, remote_details = {}, head = {}, errors = {},
  }
  local system = opts.system or vim.system
  local commands = {}

  local function add(name, args, parser, command_opts)
    commands[#commands + 1] = {
      name = name, args = args, parser = parser, opts = command_opts or {},
    }
  end

  add('status', { 'status', '--porcelain=v2', '--branch', '-z',
    '--untracked-files=all', '--ignored=no' }, function(output) parse_status(model, output) end)
  local refs_format = '%(refname)%00%(HEAD)%00%(refname:short)%00%(objectname:short)%00' ..
    '%(upstream:short)%00%(upstream:remotename)%00%(upstream:remoteref)%00' ..
    '%(upstream:trackshort)%00%(worktreepath)%00%(authorname)%00' ..
    '%(creatordate:unix)%00%(contents:subject)'
  add('refs', { 'for-each-ref', '--sort=-creatordate', '--format=' .. refs_format,
    'refs/heads', 'refs/tags' }, function(output) parse_refs(model, output) end)
  add('worktrees', { 'worktree', 'list', '--porcelain', '-z' },
    function(output) parse_worktrees(model, output, root) end)
  local log_format = '%h%x00%G?%x00%an%x00%at%x00%s%x00%D'
  add('commits', { 'log', '-n', '30', '--format=' .. log_format, '-z',
    '--decorate=short', 'HEAD' }, function(output) parse_commits(model.commits, output) end)
  add('unpushed', { 'log', 'HEAD', '--not', '--remotes', '-z',
    '--format=' .. log_format, '-n', '51' },
    function(output) parse_commits(model.unpushed, output, 51) end)
  add('pushes', { 'log', '-g', '-z', '--date=short',
    '--format=%H%x00%h%x00%gd%x00%gs%x00%s', '-n', '80', '@{upstream}' },
    function(output) parse_pushes(model, output) end)
  add('stashes', { 'stash', 'list', '-z', '--format=%gd%x00%h%x00%at%x00%s' },
    function(output) parse_stashes(model, output) end)
  add('remotes', { 'remote', '-v' }, function(output) parse_remotes(model, output) end)
  add('count', { 'rev-list', '--count', 'HEAD' }, function(output)
    model.commit_count = tonumber(chomp(output))
  end)
  add('operation', { 'rev-parse', '--absolute-git-dir' }, function(output)
    local git_dir = chomp(output)
    local function has(name) return git_dir ~= '' and uv.fs_stat(git_dir .. '/' .. name) ~= nil end
    if has('MERGE_HEAD') then model.op = 'merge'
    elseif has('CHERRY_PICK_HEAD') then model.op = 'cherry-pick'
    elseif has('REVERT_HEAD') then model.op = 'revert'
    elseif has('rebase-merge') or has('rebase-apply') then model.op = 'rebase' end
  end)

  local pending = #commands
  local completed = false
  local function finish_one()
    pending = pending - 1
    if pending == 0 and not completed then
      completed = true
      callback(finalize(model))
    end
  end

  for _, spec in ipairs(commands) do
    local command = { 'git' }
    vim.list_extend(command, spec.args)
    local ok, failure = pcall(system, command, {
      text = true,
      cwd = spec.opts.cwd or root,
      env = { LC_ALL = 'C', GIT_OPTIONAL_LOCKS = '0' },
    }, function(result)
      vim.schedule(function()
        if result.code == 0 then
          local parsed, parse_error = pcall(spec.parser, result.stdout or '')
          if not parsed then model.errors[#model.errors + 1] = spec.name .. ': ' .. tostring(parse_error) end
        elseif spec.name == 'status' then
          model.errors[#model.errors + 1] = spec.name .. ': ' .. chomp(result.stderr)
        end
        finish_one()
      end)
    end)
    if not ok then
      model.errors[#model.errors + 1] = spec.name .. ': ' .. tostring(failure)
      finish_one()
    end
  end
end

return M
