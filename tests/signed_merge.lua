local signed_merge = require('git_panel.signed_merge')

local fixture = vim.fn.tempname()

local function trim(value)
  return (value or ''):match('^%s*(.-)%s*$')
end

local function command(args, cwd, allow_failure)
  local result = vim.system(args, {
    cwd = cwd or fixture,
    text = true,
    env = { LC_ALL = 'C', GIT_CONFIG_NOSYSTEM = '1' },
  }):wait()
  if not allow_failure then
    assert(result.code == 0, ('%s failed:\n%s%s'):format(
      table.concat(args, ' '), result.stdout or '', result.stderr or ''))
  end
  return result
end

local function git(cwd, args, allow_failure)
  local argv = { 'git' }
  vim.list_extend(argv, args)
  return command(argv, cwd, allow_failure)
end

local function run()
  assert(vim.fn.executable('git') == 1, 'git is required')
  assert(vim.fn.executable('ssh-keygen') == 1, 'ssh-keygen is required for the signing fixture')
  assert(vim.fn.mkdir(fixture, 'p') == 1, 'failed to create signed-merge fixture')

  local remote = fixture .. '/remote.git'
  local repository = fixture .. '/repository'
  local hooks = fixture .. '/hooks'
  local signing_key = fixture .. '/signing-key'
  assert(vim.fn.mkdir(hooks, 'p') == 1, 'failed to create empty hooks directory')

  git(fixture, { 'init', '--bare', remote })
  git(fixture, { 'init', '--initial-branch=bet', repository })
  command({
    'ssh-keygen', '-q', '-t', 'ed25519', '-N', '',
    '-C', 'git-panel signed-merge fixture', '-f', signing_key,
  }, fixture)

  git(repository, { 'config', 'user.name', 'GitPanel CI' })
  git(repository, { 'config', 'user.email', 'git-panel@example.invalid' })
  git(repository, { 'config', 'commit.gpgsign', 'false' })
  git(repository, { 'config', 'gpg.format', 'ssh' })
  git(repository, { 'config', 'user.signingkey', signing_key })
  git(repository, { 'config', 'core.hooksPath', hooks })

  vim.fn.writefile({ 'base' }, repository .. '/state.txt')
  git(repository, { 'add', 'state.txt' })
  git(repository, { 'commit', '-m', 'base fixture' })
  git(repository, { 'switch', '-c', 'feature' })
  vim.fn.writefile({ 'feature' }, repository .. '/state.txt')
  git(repository, { 'commit', '-am', 'feature fixture' })
  local head_sha = trim(git(repository, { 'rev-parse', 'HEAD' }).stdout)
  git(repository, { 'switch', 'bet' })
  git(repository, { 'remote', 'add', 'origin', remote })
  git(repository, { 'push', '--set-upstream', 'origin', 'bet', 'feature' })
  git(fixture, {
    '--git-dir=' .. remote, 'update-ref', 'refs/pull/1/head', head_sha,
  })

  local result, err = signed_merge.run({
    root = repository,
    remote = 'origin',
    repository = 'octo/widgets',
    number = 1,
    title = 'Exercise a real signed merge',
    base = 'bet',
    head = 'feature',
    head_sha = head_sha,
    head_label = 'octo:feature',
    head_repository = 'octo/widgets',
  })
  assert(result, vim.inspect(err))
  assert(result.remote_branch_deleted, 'same-repository head branch was not deleted')

  local remote_base = trim(git(repository, {
    'ls-remote', '--refs', 'origin', 'refs/heads/bet',
  }).stdout):match('^(%x+)')
  assert(remote_base == result.merge_sha, 'remote base does not point at the merge commit')

  local deleted_head = git(repository, {
    'ls-remote', '--exit-code', '--refs', 'origin', 'refs/heads/feature',
  }, true)
  assert(deleted_head.code == 2, 'remote feature branch still exists')

  local raw_commit = git(repository, { 'cat-file', 'commit', result.merge_sha }).stdout or ''
  assert(raw_commit:find('\ngpgsig ', 1, true) or raw_commit:find('gpgsig ', 1, true) == 1,
    'merge commit has no embedded signature')
  local parent_line = trim(git(repository, {
    'rev-list', '--parents', '-n', '1', result.merge_sha,
  }).stdout)
  local fields = 0
  for _ in parent_line:gmatch('%S+') do fields = fields + 1 end
  assert(fields == 3, 'signed merge commit does not have exactly two parents')
end

local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(fixture, 'rf')
if not ok then error(err, 0) end

print('signed merge integration test passed')
