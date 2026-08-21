local M = {}

local function trim(value)
  return (value or ''):match('^%s*(.-)%s*$')
end

local function safe_detail(result)
  local text = trim(((result or {}).stderr or '') ~= '' and result.stderr or (result or {}).stdout)
  text = text:gsub('(https?://)[^/@%s]+@', '%1<redacted>@')
  if #text > 1000 then text = text:sub(1, 999) .. '…' end
  return text
end

local function git_error(stage, result, fallback)
  local detail = safe_detail(result)
  return {
    kind = 'git',
    stage = stage,
    code = result and result.code or nil,
    message = detail ~= '' and (fallback .. '\n' .. detail) or fallback,
  }
end

local function valid_sha(value)
  return type(value) == 'string' and (#value == 40 or #value == 64)
    and value:match('^[%da-fA-F]+$') ~= nil
end

local function valid_remote(value)
  return type(value) == 'string' and value:match('^[%w][%w._/-]*$') ~= nil
end

local function same_repository(left, right)
  return type(left) == 'string' and type(right) == 'string'
    and left:lower() == right:lower()
end

local function default_run(root, args, cwd)
  local command = { 'git' }
  vim.list_extend(command, args)
  return vim.system(command, {
    text = true,
    cwd = cwd or root,
    env = { LC_ALL = 'C', GIT_OPTIONAL_LOCKS = '0' },
  }):wait()
end

local function merge_message(spec)
  local source = trim(spec.head_label)
  if source == '' then source = trim(spec.head_repository) .. ':' .. spec.head end
  source = source:gsub('%c', ' ')
  local title = trim(spec.title):gsub('%c', ' ')
  local message = ('Merge pull request #%d from %s'):format(spec.number, source)
  if title ~= '' then message = message .. '\n\n' .. title end
  return message
end

local function remote_ref_missing(result)
  local detail = safe_detail(result):lower()
  return detail:find('remote ref does not exist', 1, true) ~= nil
    or detail:find('unable to delete', 1, true) ~= nil
      and detail:find('not exist', 1, true) ~= nil
end

function M.run(spec, opts)
  spec, opts = spec or {}, opts or {}
  if type(spec.root) ~= 'string' or spec.root == '' then
    return nil, { kind = 'configuration', message = 'signed_git needs a repository root' }
  end
  if not valid_remote(spec.remote) then
    return nil, { kind = 'configuration', message = 'signed_git needs a safe detected Git remote name' }
  end
  if type(spec.number) ~= 'number' or spec.number < 1 or spec.number ~= math.floor(spec.number) then
    return nil, { kind = 'configuration', message = 'signed_git needs a pull request number' }
  end
  if trim(spec.base) == '' or trim(spec.head) == '' then
    return nil, { kind = 'configuration', message = 'signed_git needs base and head branch names' }
  end
  if not valid_sha(spec.head_sha) then
    return nil, { kind = 'configuration', message = 'signed_git needs the exact pull request head SHA' }
  end

  local run = opts.run or function(args, cwd) return default_run(spec.root, args, cwd) end
  local function execute(stage, args, cwd, fallback)
    local ok, result = pcall(run, args, cwd, stage)
    if not ok then
      return nil, { kind = 'git', stage = stage, message = fallback .. '\n' .. tostring(result) }
    end
    result = result or { code = -1, stdout = '', stderr = '' }
    if result.code ~= 0 then return nil, git_error(stage, result, fallback) end
    return result
  end

  local base_check, base_error = execute('validate_base',
    { 'check-ref-format', '--branch', spec.base }, nil, 'Invalid pull request base branch')
  if not base_check then return nil, base_error end
  local head_check, head_error = execute('validate_head',
    { 'check-ref-format', '--branch', spec.head }, nil, 'Invalid pull request head branch')
  if not head_check then return nil, head_error end

  local fetched_base, fetch_base_error = execute('fetch_base', {
    'fetch', '--no-tags', '--quiet', spec.remote, 'refs/heads/' .. spec.base,
  }, nil, 'Could not fetch the current pull request base branch')
  if not fetched_base then return nil, fetch_base_error end
  local base_result, base_resolve_error = execute('resolve_base',
    { 'rev-parse', '--verify', 'FETCH_HEAD' }, nil, 'Could not resolve the fetched base branch')
  if not base_result then return nil, base_resolve_error end
  local base_sha = trim(base_result.stdout):lower()
  if not valid_sha(base_sha) then
    return nil, { kind = 'git', stage = 'resolve_base', message = 'Git returned an invalid base SHA' }
  end

  local fetched_head, fetch_head_error = execute('fetch_head', {
    'fetch', '--no-tags', '--quiet', spec.remote,
    ('refs/pull/%d/head'):format(spec.number),
  }, nil, 'Could not fetch the pull request head')
  if not fetched_head then return nil, fetch_head_error end
  local head_result, head_resolve_error = execute('resolve_head',
    { 'rev-parse', '--verify', 'FETCH_HEAD' }, nil, 'Could not resolve the fetched pull request head')
  if not head_result then return nil, head_resolve_error end
  local head_sha = trim(head_result.stdout):lower()
  if not valid_sha(head_sha) then
    return nil, { kind = 'git', stage = 'resolve_head', message = 'Git returned an invalid head SHA' }
  end
  if head_sha ~= spec.head_sha:lower() then
    return nil, {
      kind = 'stale',
      stage = 'resolve_head',
      message = 'The pull request head changed after GitPanel loaded it. Refresh and review the new commit before merging.',
    }
  end

  local tempname = opts.tempname or vim.fn.tempname
  local worktree = tempname()
  if type(worktree) ~= 'string' or worktree == '' or worktree:find('[\r\n]') then
    return nil, { kind = 'configuration', message = 'Could not allocate a safe temporary worktree path' }
  end

  local worktree_added = false
  local function cleanup()
    if not worktree_added then return nil end
    local ok, result = pcall(run,
      { 'worktree', 'remove', '--force', '--', worktree }, nil, 'cleanup')
    if not ok then return tostring(result) end
    if not result or result.code ~= 0 then
      return safe_detail(result) ~= '' and safe_detail(result) or 'git worktree remove failed'
    end
    worktree_added = false
    return nil
  end
  local function fail(err)
    local cleanup_error = cleanup()
    if cleanup_error then err.message = err.message .. '\nTemporary worktree cleanup failed: ' .. cleanup_error end
    return nil, err
  end

  local added, add_error = execute('add_worktree',
    { 'worktree', 'add', '--detach', '--', worktree, base_sha }, nil,
    'Could not create the temporary merge worktree')
  if not added then return nil, add_error end
  worktree_added = true

  local merged, merge_error = execute('merge', {
    'merge', '--no-ff', '--gpg-sign', '--no-edit',
    '-m', merge_message(spec), '--', head_sha,
  }, worktree, 'Could not create a signed merge commit')
  if not merged then return fail(merge_error) end

  local merge_result, merge_resolve_error = execute('resolve_merge',
    { 'rev-parse', '--verify', 'HEAD' }, worktree, 'Could not resolve the signed merge commit')
  if not merge_result then return fail(merge_resolve_error) end
  local merge_sha = trim(merge_result.stdout):lower()
  if not valid_sha(merge_sha) then
    return fail({ kind = 'git', stage = 'resolve_merge', message = 'Git returned an invalid merge SHA' })
  end

  local commit_result, inspect_error = execute('inspect_signature',
    { 'cat-file', 'commit', merge_sha }, worktree, 'Could not inspect the signed merge commit')
  if not commit_result then return fail(inspect_error) end
  local commit = commit_result.stdout or ''
  if not commit:match('^gpgsig[%w-]* ') and not commit:match('\ngpgsig[%w-]* ') then
    return fail({
      kind = 'signing',
      stage = 'inspect_signature',
      message = 'Git created a merge commit without a cryptographic signature; nothing was pushed.',
    })
  end

  local parents_result, parents_error = execute('inspect_parents',
    { 'rev-list', '--parents', '-n', '1', merge_sha }, worktree,
    'Could not verify the merge commit parents')
  if not parents_result then return fail(parents_error) end
  local parents = {}
  for value in trim(parents_result.stdout):gmatch('%S+') do
    parents[#parents + 1] = value:lower()
  end
  if #parents ~= 3 or parents[1] ~= merge_sha
      or parents[2] ~= base_sha or parents[3] ~= head_sha then
    return fail({
      kind = 'git',
      stage = 'inspect_parents',
      message = 'signed_git expected the fetched base and reviewed head as the merge parents; nothing was pushed.',
    })
  end

  local ancestry, ancestry_error = execute('verify_base',
    { 'merge-base', '--is-ancestor', base_sha, merge_sha }, worktree,
    'The signed commit does not descend from the fetched base; nothing was pushed')
  if not ancestry then return fail(ancestry_error) end

  local pushed, push_error = execute('push_base', {
    'push', '--porcelain', spec.remote, merge_sha .. ':refs/heads/' .. spec.base,
  }, nil, 'GitHub rejected the signed merge push')
  if not pushed then return fail(push_error) end

  local head_is_local = same_repository(spec.head_repository, spec.repository)
  local remote_branch_deleted = false
  local branch_delete_error
  if head_is_local and spec.head ~= spec.base then
    local head_ref = 'refs/heads/' .. spec.head
    local ok, result = pcall(run, {
      'push', '--porcelain', '--force-with-lease=' .. head_ref .. ':' .. head_sha,
      spec.remote, ':' .. head_ref,
    }, nil, 'delete_head')
    if ok and result and result.code == 0 then
      remote_branch_deleted = true
    elseif ok and remote_ref_missing(result) then
      remote_branch_deleted = true
    else
      branch_delete_error = ok and git_error('delete_head', result,
        'The merge succeeded, but Git refused to delete the remote head branch').message
        or ('The merge succeeded, but remote branch cleanup failed\n' .. tostring(result))
    end
  end

  local cleanup_error = cleanup()
  return {
    merge_sha = merge_sha,
    base_sha = base_sha,
    head_sha = head_sha,
    head_is_local = head_is_local,
    remote_branch_deleted = remote_branch_deleted,
    branch_delete_error = branch_delete_error,
    cleanup_error = cleanup_error,
  }
end

M.same_repository = same_repository

return M
