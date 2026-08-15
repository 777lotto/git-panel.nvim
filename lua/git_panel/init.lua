-- Dependency-free Git dashboard. Public entry points: open(), close(), refresh().
local api, fn, uv = vim.api, vim.fn, (vim.uv or vim.loop)
local M = {
  buf = nil,
  win = nil,
  mode = nil,        -- 'tab' | 'split'
  view = 'work',     -- 'work' (Staged/Unstaged) | 'history' (Committed/Uncommitted)
  folds = { pushed = true },  -- section_id -> collapsed; Pushed starts folded (long history)
  root = nil,        -- repo root for the active panel
  line_map = {},     -- 1-indexed line number -> item descriptor
  prev_win = nil,    -- window we came from (for opening files)
  start_dir = nil,   -- dir used to locate the repo
}
local PANEL_WIDTH = 48
local ns = api.nvim_create_namespace('gitpanel')
local home = uv.os_homedir() or ''

-- ---------------------------------------------------------------------------
-- git runner: argv only (no shell), explicit cwd, stable locale, no locks.
-- ---------------------------------------------------------------------------
local function git(args, opts)
  opts = opts or {}
  local cmd = { 'git' }
  for _, a in ipairs(args) do cmd[#cmd + 1] = a end
  local res = vim.system(cmd, {
    text = true,
    cwd = opts.cwd or M.root or M.start_dir or fn.getcwd(),
    env = { LC_ALL = 'C', GIT_OPTIONAL_LOCKS = '0' },
  }):wait()
  if res.code ~= 0 and not opts.allow_fail then
    vim.notify('git ' .. table.concat(args, ' ') .. '\n' ..
      ((res.stderr or ''):gsub('%s+$', '')), vim.log.levels.ERROR)
  end
  return res
end
local function chomp(s)
  local trimmed = (s or ''):gsub('%s+$', '')
  return trimmed
end
local function trim(s)
  return (s or ''):match('^%s*(.-)%s*$')
end
-- split on NUL, returning every field including trailing empties dropped
local function nul_split(s)
  local t = {}
  for field in (s or ''):gmatch('([^%z]*)%z') do t[#t + 1] = field end
  return t
end

local function remote_names()
  local res = git({ 'remote' }, { allow_fail = true })
  local names = {}
  if res.code == 0 then
    for name in (res.stdout or ''):gmatch('[^\r\n]+') do
      names[#names + 1] = name
    end
  end
  return names
end

-- In-progress sequencer operation, if any. Merge/cherry-pick/revert leave a
-- *_HEAD marker; rebase leaves a state directory. All live in the (possibly
-- per-worktree) git dir, so resolve it once and stat the markers — one git
-- call instead of one per marker, since this runs on every refresh.
local function op_state()
  local gd = chomp(git({ 'rev-parse', '--absolute-git-dir' }, { allow_fail = true }).stdout)
  if gd == '' then return nil end
  local function has(name) return uv.fs_stat(gd .. '/' .. name) ~= nil end
  if has('MERGE_HEAD') then return 'merge' end
  if has('CHERRY_PICK_HEAD') then return 'cherry-pick' end
  if has('REVERT_HEAD') then return 'revert' end
  if has('rebase-merge') or has('rebase-apply') then return 'rebase' end
  return nil
end

-- ---------------------------------------------------------------------------
-- Data gathering -> a plain model table.
-- ---------------------------------------------------------------------------
local function realpath(p) return (p and uv.fs_realpath(p)) or p end
local function same_path(a, b)
  a, b = realpath(a), realpath(b)
  if not a or not b then return false end
  if uv.os_uname().sysname == 'Darwin' then
    return a:lower() == b:lower() -- default macOS APFS is case-insensitive
  end
  return a == b -- Linux filesystems are normally case-sensitive
end

local function gather()
  local m = { branches = {}, worktrees = {}, staged = {}, unstaged = {},
              untracked = {}, conflicts = {}, commits = {}, unpushed = {},
              pushes = {}, remotes = {}, head = {} }

  m.remotes = remote_names()
  m.has_remotes = #m.remotes > 0

  -- HEAD classification (branch / detached / unborn)
  local sym = git({ 'symbolic-ref', '--quiet', '--short', 'HEAD' }, { allow_fail = true })
  local has_head = git({ 'rev-parse', '--verify', '--quiet', 'HEAD' }, { allow_fail = true })
  if sym.code == 0 and has_head.code == 0 then
    m.head.branch = chomp(sym.stdout)
  elseif sym.code == 0 and has_head.code ~= 0 then
    m.head.branch, m.head.unborn = chomp(sym.stdout), true
  else -- detached
    m.head.detached = true
    m.head.sha = chomp(git({ 'rev-parse', '--short', 'HEAD' }, { allow_fail = true }).stdout)
  end

  -- upstream + ahead/behind for current branch
  if not m.head.unborn then
    local up = git({ 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}' },
      { allow_fail = true })
    if up.code == 0 then
      m.head.upstream = chomp(up.stdout)
      local ab = git({ 'rev-list', '--left-right', '--count', '@{upstream}...HEAD' },
        { allow_fail = true })
      if ab.code == 0 then
        local behind, ahead = chomp(ab.stdout):match('(%d+)%s+(%d+)')
        m.head.behind, m.head.ahead = tonumber(behind) or 0, tonumber(ahead) or 0
      end
    end
  end

  -- local branches
  local fmt = '%(HEAD)%00%(refname:short)%00%(objectname:short)%00' ..
              '%(upstream:short)%00%(upstream:remotename)%00%(upstream:remoteref)%00' ..
              '%(upstream:trackshort)%00%(worktreepath)%00%(contents:subject)'
  local br = git({ 'for-each-ref', '--sort=-committerdate', '--format=' .. fmt, 'refs/heads' },
    { allow_fail = true })
  if br.code == 0 then
    for line in chomp(br.stdout):gmatch('[^\n]+') do
      local f = {}
      for x in (line .. '\0'):gmatch('([^%z]*)%z') do f[#f + 1] = x end
      if f[2] and f[2] ~= '' then
        m.branches[#m.branches + 1] = {
          current = (f[1] == '*'), name = f[2], sha = f[3],
          upstream = (f[4] ~= '' and f[4]) or nil,
          remote = (f[5] ~= '' and f[5]) or nil,
          remote_ref = (f[6] ~= '' and f[6]) or nil,
          track = f[7] or '',
          worktree = (f[8] ~= '' and f[8]) or nil,  -- folder holding this branch
          subject = f[9] or '',
        }
      end
    end
    -- show the current branch first (rest stay in committerdate order)
    for idx, b in ipairs(m.branches) do
      if b.current then table.remove(m.branches, idx); table.insert(m.branches, 1, b); break end
    end
  end

  -- worktrees (porcelain -z: NUL-terminated attrs, empty field = record break)
  local wt = git({ 'worktree', 'list', '--porcelain', '-z' }, { allow_fail = true })
  if wt.code == 0 then
    local cur = {}
    local function flush()
      if cur.path then
        local label = '(bare)'
        if cur.branch then label = cur.branch:gsub('^refs/heads/', '')
        elseif cur.detached and cur.HEAD then label = cur.HEAD:sub(1, 7) .. ' (detached)' end
        m.worktrees[#m.worktrees + 1] = {
          path = cur.path, label = label,
          current = same_path(cur.path, M.root),
          flags = { locked = cur.locked, prunable = cur.prunable, bare = cur.bare },
        }
      end
      cur = {}
    end
    for _, tok in ipairs(nul_split(wt.stdout)) do
      if tok == '' then
        flush()
      else
        local key, val = tok:match('^(%S+)%s?(.*)$')
        if key == 'worktree' then cur.path = val
        elseif key == 'HEAD' then cur.HEAD = val
        elseif key == 'branch' then cur.branch = val
        elseif key == 'bare' then cur.bare = true
        elseif key == 'detached' then cur.detached = true
        elseif key == 'locked' then cur.locked = true
        elseif key == 'prunable' then cur.prunable = true end
      end
    end
    flush()
  end

  -- working-tree status (porcelain v2 -z)
  local st = git({ 'status', '--porcelain=v2', '-z', '--untracked-files=all', '--ignored=no' },
    { allow_fail = true })
  if st.code == 0 then
    local toks = nul_split(st.stdout)
    local i = 1
    while i <= #toks do
      local tok = toks[i]
      local kind = tok:sub(1, 1)
      if kind == '1' then
        local xy = tok:sub(3, 4)
        local path = tok:match('^%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+(.+)$')
        local rec = { x = xy:sub(1, 1), y = xy:sub(2, 2), path = path }
        if rec.x ~= '.' then m.staged[#m.staged + 1] = rec end
        if rec.y ~= '.' then m.unstaged[#m.unstaged + 1] = rec end
        i = i + 1
      elseif kind == '2' then
        local xy = tok:sub(3, 4)
        local path = tok:match('^%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+(.+)$')
        local orig = toks[i + 1]  -- rename/copy consumes an extra NUL field
        local rec = { x = xy:sub(1, 1), y = xy:sub(2, 2), path = path, orig = orig }
        if rec.x ~= '.' then m.staged[#m.staged + 1] = rec end
        if rec.y ~= '.' then m.unstaged[#m.unstaged + 1] = rec end
        i = i + 2
      elseif kind == 'u' then
        local xy = tok:sub(3, 4)
        local path = tok:match('^u%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+(.+)$')
        m.conflicts[#m.conflicts + 1] = { x = xy:sub(1, 1), y = xy:sub(2, 2), path = path }
        i = i + 1
      elseif kind == '?' then
        m.untracked[#m.untracked + 1] = { path = tok:sub(3) }
        i = i + 1
      else
        i = i + 1
      end
    end
  end

  -- combined "uncommitted" list (dedup by display path) for the history view
  local seen, uncommitted = {}, {}
  local function add_unc(rec, badge)
    local key = rec.path
    if seen[key] then return end
    seen[key] = true
    uncommitted[#uncommitted + 1] = { x = rec.x, y = rec.y, path = rec.path, orig = rec.orig, badge = badge }
  end
  for _, r in ipairs(m.conflicts) do add_unc(r, 'conflict') end
  for _, r in ipairs(m.staged) do add_unc(r) end
  for _, r in ipairs(m.unstaged) do add_unc(r) end
  for _, r in ipairs(m.untracked) do add_unc({ x = '?', y = '?', path = r.path }, 'untracked') end
  m.uncommitted = uncommitted

  -- recent commits (skip when unborn — git log would fail)
  if not m.head.unborn then
    -- %G? = signature status per commit (G/U good, N none, E can't check, …).
    -- Costs one gpg verification per *signed* commit; unsigned rows are free.
    local lg = git({ 'log', '-n', '30', '--format=%h%x00%G?%x00%s%x00%D', '-z',
      '--decorate=short', 'HEAD' }, { allow_fail = true })
    if lg.code == 0 then
      local toks = nul_split(lg.stdout)
      for j = 1, #toks - 3, 4 do
        m.commits[#m.commits + 1] = { sha = toks[j], sig = toks[j + 1],
          subject = toks[j + 2], refs = toks[j + 3] }
      end
    end
  end

  -- committed-but-not-pushed: reachable from HEAD, not from ANY remote ref.
  -- Correct without an upstream (still catches local-only commits) and when
  -- the branch was pushed to a different remote. Gated on there being at
  -- least one configured remote. When a remote has no tracking refs yet,
  -- "--not --remotes" intentionally lists the whole local history: none of it
  -- has been observed on a remote, which is the useful result after attaching
  -- a new/empty remote or after an initial push fails.
  -- Fetches 51 to detect (and flag) the >50 overflow case.
  if not m.head.unborn then
    if m.has_remotes then
      local un = git({ 'log', 'HEAD', '--not', '--remotes', '-z',
        '--format=%h%x00%G?%x00%s%x00%D', '-n', '51' }, { allow_fail = true })
      if un.code == 0 then
        local toks = nul_split(un.stdout)
        for j = 1, #toks - 3, 4 do
          m.unpushed[#m.unpushed + 1] = { sha = toks[j], sig = toks[j + 1],
            subject = toks[j + 2], refs = toks[j + 3] }
        end
      end
    end
  end

  -- push history: the reflog of the upstream tracking ref. The reflog is a
  -- contiguous journal, so entry i's *previous* ref state is entry i+1's
  -- commit — the commits that entry introduced are therefore old..new. We
  -- record old before filtering to push entries so ranges stay correct even
  -- when a fetch/pull sits between two pushes. We show the reflog date (%gd,
  -- when the push happened) and the tip commit's subject (%s) — NOT %cs (the
  -- commit's own date) nor %gs (which is just "update by push" for every row,
  -- and is used only to identify pushes).
  if m.head.upstream then
    local rl = git({ 'log', '-g', '-z', '--date=short',
      '--format=%H%x00%h%x00%gd%x00%gs%x00%s', '-n', '80', m.head.upstream },
      { allow_fail = true })
    if rl.code == 0 then
      local toks = nul_split(rl.stdout)
      local entries = {}
      for j = 1, #toks - 4, 5 do
        entries[#entries + 1] = { new = toks[j], short = toks[j + 1],
                                  date = (toks[j + 2]:match('@{(.-)}$') or ''),
                                  reflog = toks[j + 3], subject = toks[j + 4] }
      end
      for idx, e in ipairs(entries) do
        e.old = entries[idx + 1] and entries[idx + 1].new or nil
        if (e.reflog or ''):lower():find('push', 1, true) then
          m.pushes[#m.pushes + 1] = e
        end
      end
    end
  end

  m.op = op_state()   -- in-progress merge/rebase/cherry-pick/revert (or nil)

  return m
end

-- ---------------------------------------------------------------------------
-- Rendering: model -> (lines, line_map, highlights)
-- ---------------------------------------------------------------------------
local function tilde(p)
  if home ~= '' and p:sub(1, #home) == home then return '~' .. p:sub(#home + 1) end
  return p
end
local function status_letter(rec)
  -- prefer the meaningful side; renames show R, untracked ?, etc.
  local c = rec.x ~= '.' and rec.x or rec.y
  if c == '.' or c == nil then c = '?' end
  return c
end

local function render(m)
  local lines, map, hls = {}, {}, {}
  local function emit(text, item, hl)
    lines[#lines + 1] = text
    local lnum = #lines
    if item then map[lnum] = item end
    if hl then hls[#hls + 1] = { line = lnum - 1, cs = 0, ce = #text, group = hl } end
    return lnum
  end
  local function span(lnum, cs, ce, group)
    hls[#hls + 1] = { line = lnum - 1, cs = cs, ce = ce, group = group }
  end
  local function folded(id) return M.folds[id] == true end
  local function chevron(id) return folded(id) and '▸' or '▾' end

  -- ---- header -----------------------------------------------------------
  local name = fn.fnamemodify(M.root or '', ':t')
  local hl
  if m.head.unborn then
    hl = (m.head.branch or 'HEAD') .. '  (no commits yet)'
  elseif m.head.detached then
    hl = 'detached @ ' .. (m.head.sha or '?')
  else
    hl = m.head.branch or '?'
    local extra = {}
    if m.head.ahead and m.head.ahead > 0 then extra[#extra + 1] = '↑' .. m.head.ahead end
    if m.head.behind and m.head.behind > 0 then extra[#extra + 1] = '↓' .. m.head.behind end
    if m.head.upstream and #extra == 0 then extra[#extra + 1] = '✓' end
    if #extra > 0 then hl = hl .. '  ' .. table.concat(extra, ' ') end
  end
  local hline = emit('  ' .. name .. '  on  ' .. hl, { kind = 'head' }, 'GitPanelHeader')
  span(hline, 2, 2 + #name, 'GitPanelTitle')
  emit('  <Tab> switch view · s/u stage · S/C stage·commit all · g? help · q quit',
    nil, 'GitPanelHint')
  -- in-progress merge/rebase/cherry-pick/revert banner
  if m.op then
    local OP = { merge = 'MERGING', rebase = 'REBASING',
                 ['cherry-pick'] = 'CHERRY-PICKING', revert = 'REVERTING' }
    local n = #m.conflicts
    local status = (n > 0) and (n .. ' conflict' .. (n == 1 and '' or 's') .. ' to resolve')
                            or 'all conflicts resolved'
    -- git inverts ours/theirs during a rebase (you replay onto the base), so
    -- spell out the meaning to avoid discarding the wrong side.
    local sides = (m.op == 'rebase') and 'o ours(base) · t theirs(your commit)'
                                      or  'o ours · t theirs'
    emit('  ⚠ ' .. (OP[m.op] or m.op:upper()) .. ' — ' .. status ..
      '   ·  ' .. sides .. ' · > continue · A abort', { kind = 'op' }, 'GitPanelOp')
  end
  emit('')

  -- ---- a foldable section with header + body rows ------------------------
  local function section(id, title, count, render_body)
    local head_item = { kind = 'section', section = id }
    local h = emit(' ' .. chevron(id) .. ' ' .. title ..
      (count ~= nil and ('  (' .. count .. ')') or ''), head_item, 'GitPanelSection')
    span(h, 1, 4, 'GitPanelHint')
    if not folded(id) then render_body() end
  end
  local function empty_row(text)
    emit('     ' .. text, nil, 'GitPanelHint')
  end
  -- a file/change row with a coloured status letter
  local function file_row(rec, section_id, staged)
    local letter = status_letter(rec)
    local disp = rec.path
    if rec.orig then disp = rec.orig .. ' → ' .. rec.path end
    local prefix = '     ' .. letter .. '  '
    local lnum = emit(prefix .. disp,
      { kind = 'file', value = rec.path, orig = rec.orig, section = section_id,
        staged = staged, untracked = (letter == '?'),
        conflict = (rec.badge == 'conflict') or nil })
    local grp = 'GitPanelUnstaged'
    if rec.badge == 'conflict' or letter == 'U' then grp = 'GitPanelConflict'
    elseif letter == '?' then grp = 'GitPanelUntracked'
    elseif staged then grp = 'GitPanelStaged' end
    span(lnum, 5, 6, grp)                       -- the status letter
    if rec.orig then span(lnum, #prefix, #prefix + #rec.orig, 'GitPanelHint') end
  end
  -- a conflicted-file row: <XY>  <path>   (both modified)
  local CONFLICT_KIND = {
    DD = 'both deleted', AU = 'added by us', UD = 'deleted by them',
    UA = 'added by them', DU = 'deleted by us', AA = 'both added', UU = 'both modified',
  }
  local function conflict_row(rec)
    local xy = (rec.x or '?') .. (rec.y or '?')
    local label = CONFLICT_KIND[xy] or 'unmerged'
    local prefix = '     ' .. xy .. '  '
    local lnum = emit(prefix .. rec.path .. '   (' .. label .. ')',
      { kind = 'file', value = rec.path, section = 'conflicts', conflict = true })
    span(lnum, 5, 5 + #xy, 'GitPanelConflict')            -- the XY code
    span(lnum, #prefix + #rec.path, -1, 'GitPanelHint')   -- the "(label)"
  end
  -- a commit row: <sha> <sig> <subject>  (refs)
  -- sig glyph from git's %G?: ✓ good signature (G, or U = good/unknown trust),
  -- ✗ unsigned (N), ? signed but unverifiable here (E = key missing),
  -- ! bad/expired/revoked (B/X/Y/R). Absent sig field (push rows reuse
  -- commit_row callers that predate the field) renders no glyph.
  local sig_glyphs = {
    G = { '✓', 'GitPanelSigOk' },   U = { '✓', 'GitPanelSigOk' },
    N = { '✗', 'GitPanelSigNone' }, E = { '?', 'GitPanelSigUnknown' },
    B = { '!', 'GitPanelSigBad' },  X = { '!', 'GitPanelSigBad' },
    Y = { '!', 'GitPanelSigBad' },  R = { '!', 'GitPanelSigBad' },
  }
  local function commit_row(c, section_id)
    local refs = (c.refs and c.refs ~= '') and ('  (' .. c.refs .. ')') or ''
    local prefix = '     '
    local glyph, glyph_hl = '', nil
    local g = c.sig and sig_glyphs[c.sig]
    if g then glyph, glyph_hl = g[1] .. ' ', g[2] end
    local lnum = emit(prefix .. c.sha .. '  ' .. glyph .. c.subject .. refs,
      { kind = 'commit', value = c.sha, section = section_id })
    span(lnum, #prefix, #prefix + #c.sha, 'GitPanelHash')
    if glyph_hl then
      span(lnum, #prefix + #c.sha + 2, #prefix + #c.sha + 2 + #glyph, glyph_hl)
    end
    if refs ~= '' then
      span(lnum, #prefix + #c.sha + 2 + #glyph + #c.subject, -1, 'GitPanelRef')
    end
  end
  -- a push row: <sha>  <date>  <reflog subject>. <CR> shows old..new commits.
  local function push_row(e)
    local prefix = '     '
    local date = (e.date and e.date ~= '') and (e.date .. '  ') or ''
    local lnum = emit(prefix .. e.short .. '  ' .. date .. (e.subject or ''),
      { kind = 'push', value = e.new, old = e.old, section = 'pushed' })
    span(lnum, #prefix, #prefix + #e.short, 'GitPanelHash')
    if date ~= '' then
      span(lnum, #prefix + #e.short + 2, #prefix + #e.short + 2 + #e.date, 'GitPanelHint')
    end
  end

  -- ---- Branches (permanent) --------------------------------------------
  section('branches', 'Branches', #m.branches, function()
    if #m.branches == 0 then return empty_row('(no branches)') end
    for _, b in ipairs(m.branches) do
      local marker = b.current and '*' or ' '
      local row = '     ' .. marker .. ' ' .. b.name
      local tr = b.track ~= '' and b.track or ''
      if tr ~= '' then row = row .. '  ' .. tr end
      -- branch checked out in ANOTHER worktree: show which folder holds it
      if b.worktree and not b.current then
        row = row .. '  ⊘ ' .. fn.fnamemodify(b.worktree, ':t')
      end
      local lnum = emit(row,
        { kind = 'branch', value = b.name, current = b.current, worktree = b.worktree,
          upstream = b.upstream, remote = b.remote, remote_ref = b.remote_ref })
      if b.current then span(lnum, 5, 7 + #b.name, 'GitPanelBranchCurrent')
      elseif b.worktree then span(lnum, 7 + #b.name, -1, 'GitPanelHint') end
    end
  end)
  emit('')

  -- ---- Worktrees (permanent) -------------------------------------------
  section('worktrees', 'Worktrees', #m.worktrees, function()
    if #m.worktrees == 0 then return empty_row('(no worktrees)') end
    for _, w in ipairs(m.worktrees) do
      local marker = w.current and '*' or ' '
      local flags = {}
      if w.flags.locked then flags[#flags + 1] = 'locked' end
      if w.flags.prunable then flags[#flags + 1] = 'prunable' end
      local row = '     ' .. marker .. ' ' .. tilde(w.path) .. '   ' .. w.label
      if #flags > 0 then row = row .. '  [' .. table.concat(flags, ',') .. ']' end
      local lnum = emit(row, { kind = 'worktree', value = w.path, current = w.current })
      if w.current then span(lnum, 5, #row, 'GitPanelWorktreeCurrent') end
    end
  end)
  emit('')

  -- ---- Changes region: divider that toggles the view --------------------
  local function divider(label, hint)
    local lnum = emit('── ' .. label .. ' ' .. string.rep('─', math.max(2, 40 - #label)),
      { kind = 'viewheader' }, 'GitPanelDivider')
    emit('     ' .. hint, nil, 'GitPanelHint')
  end

  if M.view == 'work' then
    divider('Staged / Unstaged', '<Tab> → Committed / Uncommitted')
    if m.op or #m.conflicts > 0 then
      section('conflicts', 'Conflicts', #m.conflicts, function()
        if #m.conflicts == 0 then
          return empty_row('(all resolved — > continue · A abort)')
        end
        for _, r in ipairs(m.conflicts) do conflict_row(r) end
      end)
    end
    section('staged', 'Staged', #m.staged, function()
      if #m.staged == 0 then return empty_row('(nothing staged)') end
      for _, r in ipairs(m.staged) do file_row(r, 'staged', true) end
    end)
    section('unstaged', 'Unstaged', #m.unstaged, function()
      if #m.unstaged == 0 then return empty_row('(nothing unstaged)') end
      for _, r in ipairs(m.unstaged) do file_row(r, 'unstaged', false) end
    end)
    section('untracked', 'Untracked', #m.untracked, function()
      if #m.untracked == 0 then return empty_row('(no untracked files)') end
      for _, r in ipairs(m.untracked) do
        file_row({ x = '?', y = '?', path = r.path }, 'untracked', false)
      end
    end)
    local ucount = (#m.unpushed > 50) and '50+' or #m.unpushed
    section('unpushed', 'Committed (not pushed)', ucount, function()
      if #m.unpushed == 0 then
        return empty_row(m.has_remotes and '(nothing to push)' or
          '(no remote configured — P to publish)')
      end
      local shown = math.min(#m.unpushed, 50)
      for i = 1, shown do commit_row(m.unpushed[i], 'unpushed') end
      if #m.unpushed > 50 then
        empty_row('… more commits not shown (see ↑ ahead-count in the header)')
      end
    end)
    section('pushed', 'Pushed', #m.pushes, function()
      if #m.pushes == 0 then return empty_row('(no pushes recorded)') end
      for _, e in ipairs(m.pushes) do push_row(e) end
    end)
  else
    divider('Committed / Uncommitted', '<Tab> → Staged / Unstaged')
    section('uncommitted', 'Uncommitted', #m.uncommitted, function()
      if #m.uncommitted == 0 then return empty_row('(working tree clean)') end
      for _, r in ipairs(m.uncommitted) do file_row(r, 'uncommitted', r.x ~= '.' and r.x ~= '?') end
    end)
    section('committed', 'Committed (recent)', nil, function()
      if #m.commits == 0 then return empty_row('(no commits yet)') end
      for _, c in ipairs(m.commits) do commit_row(c, 'committed') end
    end)
  end

  return lines, map, hls
end

-- ---------------------------------------------------------------------------
-- Highlight groups (re-applied on ColorScheme so they survive a theme reload)
-- ---------------------------------------------------------------------------
local function define_hl()
  local link = function(a, b) api.nvim_set_hl(0, a, { link = b, default = true }) end
  link('GitPanelHeader', 'Title')
  link('GitPanelTitle', 'Directory')
  link('GitPanelHint', 'Comment')
  link('GitPanelSection', 'Statement')
  link('GitPanelDivider', 'Title')
  link('GitPanelBranchCurrent', 'Function')
  link('GitPanelWorktreeCurrent', 'Function')
  link('GitPanelStaged', 'DiagnosticOk')
  link('GitPanelUnstaged', 'DiagnosticWarn')
  link('GitPanelUntracked', 'DiagnosticHint')
  link('GitPanelConflict', 'DiagnosticError')
  link('GitPanelOp', 'WarningMsg')
  link('GitPanelHash', 'Constant')
  link('GitPanelRef', 'Special')
  link('GitPanelSigOk', 'DiagnosticOk')
  link('GitPanelSigNone', 'DiagnosticWarn')
  link('GitPanelSigUnknown', 'DiagnosticHint')
  link('GitPanelSigBad', 'DiagnosticError')
end

-- ---------------------------------------------------------------------------
-- Buffer / window lifecycle
-- ---------------------------------------------------------------------------
local function with_writable(fnc)
  api.nvim_set_option_value('modifiable', true, { buf = M.buf })
  local ok, err = pcall(fnc)
  api.nvim_set_option_value('modifiable', false, { buf = M.buf })
  if not ok then error(err) end
end

local function find_win()
  if not (M.buf and api.nvim_buf_is_valid(M.buf)) then return nil end
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(w) == M.buf then return w end
  end
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(w) == M.buf then return w end
  end
  return nil
end

function M.refresh()
  if not (M.buf and api.nvim_buf_is_valid(M.buf)) then return end
  local win = find_win()
  -- remember the logical item under the cursor to restore it after rebuild
  local function item_key(it)
    return (it.kind or '') .. '\0' .. tostring(it.value or '') .. '\0' ..
           tostring(it.section or '') .. '\0' .. tostring(it.old or '')
  end
  local prev_key
  if win then
    local it = M.line_map[api.nvim_win_get_cursor(win)[1]]
    if it then prev_key = item_key(it) end
  end

  local model = gather()
  local lines, map, hls = render(model)
  M.line_map = map
  with_writable(function() api.nvim_buf_set_lines(M.buf, 0, -1, false, lines) end)

  api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    pcall(api.nvim_buf_set_extmark, M.buf, ns, h.line, h.cs,
      { end_col = (h.ce == -1) and nil or h.ce, end_row = (h.ce == -1) and h.line + 1 or nil,
        hl_group = h.group })
  end

  if win and prev_key then
    for lnum, it in pairs(map) do
      if item_key(it) == prev_key then
        pcall(api.nvim_win_set_cursor, win, { lnum, 0 })
        break
      end
    end
  end
end

local function set_win_opts(win)
  local w = function(n, v) api.nvim_set_option_value(n, v, { win = win }) end
  w('number', false); w('relativenumber', false); w('signcolumn', 'no')
  w('cursorline', true); w('wrap', false); w('list', false); w('foldcolumn', '0')
  w('winfixwidth', true)
end

local function ensure_buf()
  if M.buf and api.nvim_buf_is_valid(M.buf) then return M.buf end
  local buf = api.nvim_create_buf(false, true)
  local o = function(n, v) api.nvim_set_option_value(n, v, { buf = buf }) end
  o('buftype', 'nofile'); o('bufhidden', 'hide'); o('swapfile', false)
  o('buflisted', false); o('filetype', 'gitpanel'); o('modifiable', false)
  pcall(api.nvim_buf_set_name, buf, 'gitpanel://status')
  M.buf = buf
  M.attach_keys()
  return buf
end

local function open_tab()
  vim.cmd('tabnew')
  M.win = api.nvim_get_current_win()
  api.nvim_win_set_buf(M.win, M.buf)
  set_win_opts(M.win); M.mode = 'tab'
end
local function open_split()
  vim.cmd('topleft vsplit')
  M.win = api.nvim_get_current_win()
  api.nvim_win_set_buf(M.win, M.buf)
  api.nvim_win_set_width(M.win, PANEL_WIDTH)
  set_win_opts(M.win); M.mode = 'split'
end

local function detect_root()
  local cur = api.nvim_get_current_win()
  if cur ~= M.win then M.prev_win = cur end
  local bufname = api.nvim_buf_get_name(0)
  local dir = (bufname ~= '' and fn.filereadable(bufname) == 1) and fn.fnamemodify(bufname, ':p:h')
    or fn.getcwd()
  M.start_dir = dir
  local r = vim.system({ 'git', 'rev-parse', '--show-toplevel' },
    { text = true, cwd = dir }):wait()
  if r.code ~= 0 then return nil end
  return chomp(r.stdout)
end

function M.open(mode)
  mode = mode or 'tab'
  local root = detect_root()
  if not root then
    vim.notify('GitPanel: not inside a git repository (' .. (M.start_dir or '?') .. ')',
      vim.log.levels.WARN)
    return
  end
  M.root = root
  ensure_buf()
  local existing = find_win()
  if existing then
    M.win = existing
    api.nvim_set_current_win(existing)
    if M.mode ~= mode then M.toggle_layout() else M.refresh() end
    return
  end
  if mode == 'tab' then open_tab() else open_split() end
  M.refresh()
end

function M.close()
  local win = find_win()
  if not win then return end
  local last_win = #api.nvim_tabpage_list_wins(0) == 1
  local last_tab = fn.tabpagenr('$') == 1
  if last_win and last_tab then
    api.nvim_set_current_win(win); vim.cmd('enew')
  else
    pcall(api.nvim_win_close, win, true)
  end
  M.win, M.mode = nil, nil
end

function M.toggle_layout()
  local win = find_win()
  if not win then return M.open('split') end
  local target = (M.mode == 'tab') and 'split' or 'tab'
  api.nvim_set_current_win(win)
  -- Vacate the current panel window before building the new layout, so the
  -- panel buffer is never left showing in a stranded second window. Close it
  -- outright when something else would remain; otherwise swap in a scratch buf.
  if #api.nvim_tabpage_list_wins(0) > 1 or fn.tabpagenr('$') > 1 then
    pcall(api.nvim_win_close, win, true)
  else
    api.nvim_win_set_buf(win, api.nvim_create_buf(false, true))
  end
  if target == 'tab' then open_tab() else open_split() end
  M.refresh()
end

function M.toggle_view()
  M.view = (M.view == 'work') and 'history' or 'work'
  M.refresh()
end

function M.toggle_fold()
  local it = M.line_map[api.nvim_win_get_cursor(0)[1]]
  if it and it.section then
    M.folds[it.section] = not M.folds[it.section]
    M.refresh()
  elseif it and it.kind == 'viewheader' then
    M.toggle_view()
  end
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------
local function cur_item() return M.line_map[api.nvim_win_get_cursor(0)[1]] end
-- Run a mutating git command. Notifies on failure unless opts.quiet (callers
-- that inspect stderr themselves pass quiet=true to avoid a double message).
local function run(args, opts)
  opts = opts or {}
  local res = git(args, { allow_fail = true, cwd = opts.cwd })
  if res.code ~= 0 and not opts.quiet then
    vim.notify('git ' .. table.concat(args, ' ') .. '\n' .. chomp(res.stderr), vim.log.levels.WARN)
  end
  return res.code == 0, res
end

local function open_file(path, jump_conflict)
  local full = (M.root or '') .. '/' .. path
  local target
  -- Reuse a window only if it lives in the CURRENT tabpage, so tab-mode never
  -- yanks focus to a different tab. prev_win qualifies only when co-located.
  local here = {}
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do here[w] = true end
  if M.prev_win and here[M.prev_win] and api.nvim_win_is_valid(M.prev_win)
      and api.nvim_win_get_buf(M.prev_win) ~= M.buf then
    target = M.prev_win
  else
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_get_buf(w) ~= M.buf then target = w; break end
    end
  end
  if target then
    api.nvim_set_current_win(target)
    vim.cmd('edit ' .. fn.fnameescape(full))
  elseif M.mode == 'split' then
    vim.cmd('rightbelow vsplit ' .. fn.fnameescape(full))
  else
    vim.cmd('split ' .. fn.fnameescape(full))
  end
  -- land on the first conflict marker so the user can start resolving at once
  if jump_conflict then pcall(fn.search, '^<<<<<<<', 'cw') end
end

-- open git output in a throwaway split, filetype=git, q to close
local function show_scratch(text)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text or '', '\n', { plain = true }))
  api.nvim_set_option_value('filetype', 'git', { buf = buf })
  api.nvim_set_option_value('modifiable', false, { buf = buf })
  if M.mode == 'split' then vim.cmd('rightbelow vsplit') else vim.cmd('botright split') end
  api.nvim_win_set_buf(0, buf)
  vim.keymap.set('n', 'q', '<cmd>close<cr>', { buffer = buf, nowait = true, silent = true })
end
local function show_commit(sha)
  show_scratch(git({ 'show', '--stat', '--patch', sha }, { allow_fail = true }).stdout)
end
-- Show the commits a push introduced: old..new. The oldest recorded push has
-- no known prior state, so fall back to showing its tip commit alone.
local function show_push(it)
  if it.old and it.old ~= '' then
    local res = git({ 'log', '--stat', '--patch', it.old .. '..' .. it.value }, { allow_fail = true })
    local out = res.stdout or ''
    if out:gsub('%s+', '') == '' then
      out = '(no commits to list for this push — the ref update introduced nothing new\n' ..
            'over its previous position, e.g. a re-push or a force update to ' .. it.value .. ')'
    end
    show_scratch(out)
  else
    show_scratch('(oldest recorded push — showing the pushed tip commit)\n\n' ..
      (git({ 'show', '--stat', '--patch', it.value }, { allow_fail = true }).stdout or ''))
  end
end

function M.primary()
  local it = cur_item()
  if not it then return end
  if it.kind == 'section' or it.kind == 'viewheader' then M.toggle_fold()
  elseif it.kind == 'branch' then M.checkout(it.value)
  elseif it.kind == 'worktree' then M.switch_worktree(it.value)
  elseif it.kind == 'file' then open_file(it.value, it.conflict)
  elseif it.kind == 'commit' then show_commit(it.value)
  elseif it.kind == 'push' then show_push(it)
  elseif it.kind == 'op' then M.op_continue()
  end
end

-- Any file still in an unmerged (conflicted) state?
local function has_conflicts()
  local r = git({ 'diff', '--name-only', '--diff-filter=U' }, { allow_fail = true })
  return r.code == 0 and chomp(r.stdout) ~= ''
end

function M.stage()
  local it = cur_item()
  if not (it and it.kind == 'file') then return vim.notify('GitPanel: cursor not on a file', vim.log.levels.INFO) end
  -- Marking a conflict resolved (git add) while it still has markers would
  -- commit the markers; warn first. git diff --check flags leftover markers.
  if it.conflict then
    local chk = git({ 'diff', '--check', '--', it.value }, { allow_fail = true })
    if chk.code ~= 0 then
      local pick = fn.confirm('"' .. it.value .. '" still contains conflict markers ' ..
        '(<<<<<<< / =======  / >>>>>>>).\nStage it as resolved anyway?', '&Yes\n&No', 2)
      if pick ~= 1 then return end
    end
  end
  run({ 'add', '--', it.value }); M.refresh()
end
function M.unstage()
  local it = cur_item()
  if not (it and it.kind == 'file') then return vim.notify('GitPanel: cursor not on a file', vim.log.levels.INFO) end
  run({ 'reset', '-q', '--', it.value }); M.refresh()  -- works born and unborn
end
-- "Stage All" (git add -A) would sweep unresolved conflicts — marker text and
-- all — into the index; refuse while any conflict is unresolved.
function M.stage_all()
  if has_conflicts() then
    return vim.notify('GitPanel: unresolved conflicts — resolve with o/t or edit + s ' ..
      'before Stage All', vim.log.levels.WARN)
  end
  run({ 'add', '-A' }); M.refresh()
end
function M.unstage_all() run({ 'reset', '-q' }); M.refresh() end

function M.discard()
  local it = cur_item()
  if not (it and it.kind == 'file') then return end
  -- On a conflicted file "discard" is ambiguous (restore would silently pick
  -- the HEAD side); steer the user to the explicit resolve keys instead.
  if it.conflict then
    return vim.notify('GitPanel: "' .. it.value .. '" is conflicted — use o/t to take a ' ..
      'side, edit + s to resolve, or A to abort the operation', vim.log.levels.INFO)
  end
  local pick = fn.confirm('Discard changes to "' .. it.value .. '"? This cannot be undone.',
    '&Yes\n&No', 2)
  if pick ~= 1 then return end
  if it.untracked then
    run({ 'clean', '-f', '--', it.value })        -- delete the untracked file
  else
    run({ 'restore', '--staged', '--worktree', '--', it.value }) -- unstage + revert worktree
  end
  M.refresh()
end

-- ---- conflict resolution -------------------------------------------------
-- Resolve the conflicted file under the cursor by taking one whole side, then
-- stage it. "ours"/"theirs" follow git's flags: during a merge ours = HEAD
-- (current branch), theirs = the incoming branch; during a rebase they invert
-- (ours = the branch you're replaying onto). checkout --ours/--theirs only
-- works for content conflicts — for add/delete conflicts git errors and we
-- surface that so the user edits/stages manually instead.
local function resolve_side(side)
  local it = cur_item()
  if not (it and it.kind == 'file' and it.conflict) then
    return vim.notify('GitPanel: move the cursor onto a conflicted file', vim.log.levels.INFO)
  end
  local ok, res = run({ 'checkout', '--' .. side, '--', it.value }, { quiet = true })
  if not ok then
    return vim.notify('git checkout --' .. side .. ':\n' .. chomp(res.stderr) ..
      '\n(add/delete conflict — edit the file and press s to mark resolved)', vim.log.levels.WARN)
  end
  run({ 'add', '--', it.value })
  M.refresh()
end
function M.resolve_ours() resolve_side('ours') end
function M.resolve_theirs() resolve_side('theirs') end

-- Continue/finish the in-progress operation (commit the merge, advance the
-- rebase, …). core.editor=true accepts the prepared message without opening
-- an editor. git exits nonzero when it can't proceed (conflicts remain, or a
-- rebase step became empty and wants --skip) — its own message is the most
-- accurate, so we surface that verbatim and re-read state.
function M.op_continue()
  local op = op_state()
  if not op then
    return vim.notify('GitPanel: no merge/rebase/cherry-pick/revert in progress', vim.log.levels.INFO)
  end
  local ok, res = run({ '-c', 'core.editor=true', op, '--continue' }, { quiet = true })
  if not ok then
    vim.notify('git ' .. op .. ' --continue:\n' .. chomp(res.stderr) ..
      '\n(follow the message above, then > to continue or A to abort' ..
      (op == 'rebase' and '; for an empty patch: :!git rebase --skip)' or ')'),
      vim.log.levels.WARN)
  end
  M.refresh()
end
function M.op_abort()
  local op = op_state()
  if not op then
    return vim.notify('GitPanel: nothing to abort (no operation in progress)', vim.log.levels.INFO)
  end
  local pick = fn.confirm('Abort the in-progress ' .. op ..
    '?\nThis throws away the resolution done so far.', '&Yes\n&No', 2)
  if pick ~= 1 then return end
  local ok, res = run({ op, '--abort' }, { quiet = true })
  if not ok then vim.notify('git ' .. op .. ' --abort:\n' .. chomp(res.stderr), vim.log.levels.WARN) end
  M.refresh()
end

-- Signing failed (card absent, PIN cancelled, gpg broken)? Offer ONE explicit
-- fallback to an unsigned commit. Never silent: cancelling pinentry must not
-- quietly produce an unsigned commit, so the default answer is No. The panel's
-- ✓/✗ column shows what actually happened either way.
local function sign_failed(stderr)
  return stderr:find('gpg failed to sign', 1, true)
      or stderr:find('signing failed', 1, true)
end
local function run_commit(args)
  local ok, res = run(args, { quiet = true })
  if not ok and sign_failed(res.stderr) then
    local pick = fn.confirm('GPG signing failed (card absent / PIN cancelled?).\n' ..
      'Commit UNSIGNED instead?', '&Yes\n&No', 2)
    if pick == 1 then
      local retry = vim.deepcopy(args)
      table.insert(retry, 2, '--no-gpg-sign')
      ok, res = run(retry, { quiet = true })
      if ok then vim.notify('GitPanel: committed UNSIGNED', vim.log.levels.WARN) end
    end
  end
  if not ok then vim.notify('git commit:\n' .. chomp(res.stderr), vim.log.levels.ERROR) end
  return ok
end
local function do_commit(extra_args)
  vim.ui.input({ prompt = 'Commit message: ' }, function(msg)
    if not msg or msg == '' then return vim.notify('GitPanel: commit cancelled', vim.log.levels.INFO) end
    local args = { 'commit', '-m', msg }
    for _, a in ipairs(extra_args or {}) do args[#args + 1] = a end
    run_commit(args)
    M.refresh()
  end)
end
-- `c` always prompts for a message and commits. This works to finish a merge
-- (git commit completes it) and to commit at a rebase `edit` stop; to advance
-- with the prepared message (and for rebase after resolving a conflict) use
-- `>` / M.op_continue instead. git refuses to commit while conflicts remain.
function M.commit() do_commit() end
-- "Commit All" during an operation must not `git add -A` (that would sweep in
-- unresolved conflicts); once things are resolved it finishes the operation.
function M.commit_all()
  if has_conflicts() then
    return vim.notify('GitPanel: unresolved conflicts — resolve them first ' ..
      '(o/t or edit + s), then > to continue', vim.log.levels.WARN)
  end
  if op_state() then return M.op_continue() end
  run({ 'add', '-A' }); M.refresh(); do_commit()
end
function M.amend()
  vim.ui.input({ prompt = 'Amend message (empty = keep existing): ' }, function(msg)
    local args = (msg and msg ~= '') and { 'commit', '--amend', '-m', msg }
      or { 'commit', '--amend', '--no-edit' }
    run_commit(args)
    M.refresh()
  end)
end

function M.checkout(branch)
  local it = cur_item()
  branch = branch or (it and it.kind == 'branch' and it.value)
  if not branch then return end
  -- A branch checked out in another worktree cannot be switched to here (git's
  -- one-branch-per-worktree rule). Offer to jump to that worktree instead of
  -- surfacing the cryptic "'<b>' is already used by worktree at ..." error.
  if it and it.kind == 'branch' and it.worktree and not it.current then
    local pick = fn.confirm('"' .. branch .. '" is checked out in another worktree:\n  ' ..
      tilde(it.worktree) .. '\n(git allows a branch in only one worktree at a time)\n\n' ..
      'Jump to that worktree?', '&Yes\n&No', 1)
    if pick == 1 then M.switch_worktree(it.worktree) end
    return
  end
  local ok, res = run({ 'switch', '--', branch }, { quiet = true })
  if not ok then vim.notify('git switch:\n' .. chomp(res.stderr), vim.log.levels.WARN) end
  M.refresh()
end
function M.new_branch()
  vim.ui.input({ prompt = 'New branch name: ' }, function(nm)
    if not nm or nm == '' then return end
    local ok, res = run({ 'switch', '-c', nm }, { quiet = true })
    if not ok then vim.notify('git switch -c:\n' .. chomp(res.stderr), vim.log.levels.ERROR) end
    M.refresh()
  end)
end

local function rename_local_branch(old_name, new_name)
  if old_name == new_name then return true end
  local ok, res = run({ 'branch', '-m', '--', old_name, new_name }, { quiet = true })
  if not ok then
    vim.notify('git branch -m:\n' .. chomp(res.stderr), vim.log.levels.ERROR)
  end
  return ok
end

-- A Git remote has no atomic "rename branch" command. Safely emulate it by
-- creating the new ref, deleting the old ref with a lease, then updating the
-- local branch/upstream. If a host rejects deletion (commonly because the old
-- branch is its default or is protected), leave the local/upstream untouched;
-- the newly-created remote ref makes the operation safe to retry after the
-- repository setting is changed.
local function rename_remote_branch(it, new_name, rename_local)
  local old_local = it.value
  local remote = it.remote
  local old_remote = it.remote_ref and it.remote_ref:match('^refs/heads/(.+)$')
  if not remote or remote == '.' or not old_remote then
    return vim.notify('GitPanel: "' .. old_local .. '" has no tracked remote branch; ' ..
      'rename it locally, then use P to publish it', vim.log.levels.INFO)
  end

  local local_ref = 'refs/heads/' .. old_local
  local old_ref = 'refs/heads/' .. old_remote
  local new_ref = 'refs/heads/' .. new_name

  -- If only the local name differs, the remote is already named correctly.
  if old_remote == new_name then
    if rename_local and old_local ~= new_name then
      if not rename_local_branch(old_local, new_name) then M.refresh(); return end
      local ok, res = run({ 'branch', '--set-upstream-to=' .. remote .. '/' .. new_name,
        '--', new_name }, { quiet = true })
      if not ok then
        vim.notify('Branch renamed locally, but its upstream could not be set:\n' ..
          chomp(res.stderr), vim.log.levels.WARN)
      else
        vim.notify('GitPanel: renamed local branch ' .. old_local .. ' -> ' .. new_name,
          vim.log.levels.INFO)
      end
    else
      vim.notify('GitPanel: remote branch is already named ' .. remote .. '/' .. new_name,
        vim.log.levels.INFO)
    end
    M.refresh()
    return
  end

  -- Check this before touching the remote so a Both operation cannot become
  -- remote-only merely because the requested local target already exists.
  if rename_local and old_local ~= new_name then
    local exists = git({ 'show-ref', '--verify', '--quiet', 'refs/heads/' .. new_name },
      { allow_fail = true })
    if exists.code == 0 then
      return vim.notify('GitPanel: local branch already exists: ' .. new_name,
        vim.log.levels.ERROR)
    end
  end

  local local_sha_res = git({ 'rev-parse', '--verify', local_ref }, { allow_fail = true })
  if local_sha_res.code ~= 0 then
    return vim.notify('GitPanel: local branch no longer exists: ' .. old_local,
      vim.log.levels.WARN)
  end
  local local_sha = chomp(local_sha_res.stdout)

  -- Ask the server for exact ref names; remote-tracking refs may be stale.
  local ls = git({ 'ls-remote', '--heads', '--refs', remote, old_ref, new_ref },
    { allow_fail = true })
  if ls.code ~= 0 then
    return vim.notify('git ls-remote ' .. remote .. ':\n' .. chomp(ls.stderr),
      vim.log.levels.ERROR)
  end
  local heads = {}
  for line in (ls.stdout or ''):gmatch('[^\n]+') do
    local sha, ref = line:match('^(%x+)%s+(refs/heads/.+)$')
    if sha and ref then heads[ref] = sha end
  end
  local old_sha, new_sha = heads[old_ref], heads[new_ref]

  -- An existing target is accepted only when it is the same ref we are about
  -- to copy (or a copy left by an earlier, partially-completed rename).
  if new_sha and new_sha ~= local_sha and new_sha ~= old_sha then
    return vim.notify('GitPanel: refusing to overwrite existing remote branch ' ..
      remote .. '/' .. new_name, vim.log.levels.ERROR)
  end

  if old_sha then
    -- Fetch the source tip and require the selected local branch to contain it.
    -- This prevents deleting commits that exist only on the remote.
    local fetched = git({ 'fetch', '--no-tags', remote, old_ref }, { allow_fail = true })
    if fetched.code ~= 0 then
      return vim.notify('git fetch ' .. remote .. '/' .. old_remote .. ':\n' ..
        chomp(fetched.stderr), vim.log.levels.ERROR)
    end
    local tip = git({ 'rev-parse', '--verify', 'FETCH_HEAD' }, { allow_fail = true })
    if tip.code ~= 0 then
      return vim.notify('GitPanel: could not verify the remote source branch',
        vim.log.levels.ERROR)
    end
    old_sha = chomp(tip.stdout)
    local contains = git({ 'merge-base', '--is-ancestor', old_sha, local_ref },
      { allow_fail = true })
    if contains.code ~= 0 then
      return vim.notify('GitPanel: refusing to rename ' .. remote .. '/' .. old_remote ..
        ' because it has commits missing from local branch "' .. old_local ..
        '". Pull/merge that branch, then retry.', vim.log.levels.ERROR)
    end
  end

  if new_sha ~= local_sha then
    -- A lease with an empty expected value guarantees that a concurrently
    -- created target is not overwritten. For a retry, lease its known SHA.
    local expected = new_sha or ''
    local ok, res = run({ 'push', '--porcelain',
      '--force-with-lease=' .. new_ref .. ':' .. expected,
      remote, local_ref .. ':' .. new_ref }, { quiet = true })
    if not ok then
      return vim.notify('GitPanel: could not create ' .. remote .. '/' .. new_name ..
        '; the old branch was left untouched.\n' .. chomp(res.stderr), vim.log.levels.ERROR)
    end
  end

  if old_sha then
    -- The lease prevents deletion if somebody advanced the source branch
    -- after our fetch. The new ref remains as a safe copy if deletion fails.
    local ok, res = run({ 'push', '--porcelain',
      '--force-with-lease=' .. old_ref .. ':' .. old_sha,
      remote, ':' .. old_ref }, { quiet = true })
    if not ok then
      vim.notify('GitPanel: created ' .. remote .. '/' .. new_name .. ', but the server ' ..
        'refused to delete ' .. remote .. '/' .. old_remote .. '.\n' ..
        'Nothing was renamed locally and its upstream still points to the old branch. ' ..
        'If it is the default/protected branch, change that repository setting, then ' ..
        'press R again with the same new name.\n' .. chomp(res.stderr), vim.log.levels.WARN)
      M.refresh()
      return
    end
  end

  local local_name = old_local
  if rename_local and old_local ~= new_name then
    if not rename_local_branch(old_local, new_name) then
      -- The remote move is already complete; preserve a useful upstream on
      -- the still-old local name and report the recoverable partial result.
      run({ 'branch', '--set-upstream-to=' .. remote .. '/' .. new_name,
        '--', old_local }, { quiet = true })
      vim.notify('GitPanel: remote branch is now ' .. remote .. '/' .. new_name ..
        ', but the local rename failed. Its upstream was moved to the new remote branch.',
        vim.log.levels.WARN)
      M.refresh()
      return
    end
    local_name = new_name
  end

  local upstream_ok, upstream_res = run({
    'branch', '--set-upstream-to=' .. remote .. '/' .. new_name, '--', local_name,
  }, { quiet = true })
  if not upstream_ok then
    vim.notify('GitPanel: remote rename completed, but setting the upstream failed:\n' ..
      chomp(upstream_res.stderr), vim.log.levels.WARN)
  else
    local local_part = (rename_local and old_local ~= new_name)
      and ('local ' .. old_local .. ' -> ' .. new_name .. ' and ') or ''
    vim.notify('GitPanel: renamed ' .. local_part .. 'remote ' .. remote .. '/' ..
      old_remote .. ' -> ' .. remote .. '/' .. new_name, vim.log.levels.INFO)
  end
  -- Refresh origin/HEAD (or equivalent) when the server advertises one.
  git({ 'remote', 'set-head', remote, '--auto' }, { allow_fail = true })
  M.refresh()
end

function M.rename_branch()
  local it = cur_item()
  if not (it and it.kind == 'branch') then
    return vim.notify('GitPanel: move the cursor onto a branch to rename it',
      vim.log.levels.INFO)
  end
  local old_name = it.value
  vim.ui.input({ prompt = 'Rename branch "' .. old_name .. '" to: ', default = old_name },
    function(new_name)
      new_name = new_name and new_name:match('^%s*(.-)%s*$') or nil
      if not new_name or new_name == '' then
        return vim.notify('GitPanel: branch rename cancelled', vim.log.levels.INFO)
      end
      local valid = git({ 'check-ref-format', '--branch', new_name }, { allow_fail = true })
      if valid.code ~= 0 then
        return vim.notify('Invalid branch name "' .. new_name .. '":\n' ..
          chomp(valid.stderr), vim.log.levels.ERROR)
      end
      local remote_branch = it.remote_ref and it.remote_ref:match('^refs/heads/(.+)$')
      local has_remote = it.remote and it.remote ~= '.' and remote_branch
      if has_remote then
        local pick = fn.confirm(
          'Rename branch?\n\n  local:  ' .. old_name .. ' -> ' .. new_name ..
          '\n  remote: ' .. it.remote .. '/' .. remote_branch .. ' -> ' ..
          it.remote .. '/' .. new_name ..
          '\n\nRemote rename pushes the new ref and deletes the old ref.',
          '&Both (local + remote)\n&Local only\n&Remote only\n&Cancel', 4)
        if pick == 1 then return rename_remote_branch(it, new_name, true) end
        if pick == 3 then return rename_remote_branch(it, new_name, false) end
        if pick ~= 2 then return end
      end

      if old_name == new_name then
        return vim.notify('GitPanel: branch is already named ' .. new_name,
          vim.log.levels.INFO)
      end
      if rename_local_branch(old_name, new_name) then
        vim.notify('GitPanel: renamed local branch ' .. old_name .. ' -> ' .. new_name,
          vim.log.levels.INFO)
      end
      M.refresh()
    end)
end

function M.delete_branch()
  local it = cur_item()
  if not (it and it.kind == 'branch') then
    return vim.notify('GitPanel: move the cursor onto a branch to delete it', vim.log.levels.INFO)
  end
  if it.current then return vim.notify('GitPanel: cannot delete the current branch', vim.log.levels.WARN) end
  local ok, res = run({ 'branch', '-d', '--', it.value }, { quiet = true })
  if not ok then
    if (res.stderr or ''):match('not fully merged') then
      local pick = fn.confirm('Branch "' .. it.value .. '" is not fully merged. Force-delete?',
        '&Yes\n&No', 2)
      if pick == 1 then run({ 'branch', '-D', '--', it.value }) end
    else
      vim.notify('git branch -d:\n' .. chomp(res.stderr), vim.log.levels.WARN)
    end
  end
  M.refresh()
end
function M.merge()
  local it = cur_item()
  if not (it and it.kind == 'branch') then
    return vim.notify('GitPanel: move the cursor onto a branch to merge it', vim.log.levels.INFO)
  end
  if it.current then return vim.notify('GitPanel: that is already the current branch', vim.log.levels.INFO) end
  local pick = fn.confirm('Merge "' .. it.value .. '" into the current branch?', '&Yes\n&No', 1)
  if pick ~= 1 then return end
  local ok, res = run({ 'merge', '--', it.value }, { quiet = true })
  local out = chomp((res.stdout or '') .. (res.stderr or ''))
  if not ok then
    vim.notify('git merge:\n' .. out .. '\n(resolve conflicts, then commit; or :!git merge --abort)',
      vim.log.levels.WARN)
  else
    vim.notify('git merge: ' .. out, vim.log.levels.INFO)
  end
  M.refresh()
end

function M.switch_worktree(path)
  local it = cur_item()
  path = path or (it and it.kind == 'worktree' and it.value)
  if not path then return end
  if fn.isdirectory(path) == 0 then
    return vim.notify('GitPanel: worktree path missing: ' .. path, vim.log.levels.WARN)
  end
  vim.cmd('tcd ' .. fn.fnameescape(path))
  M.root = path
  vim.notify('GitPanel: switched to worktree ' .. tilde(path), vim.log.levels.INFO)
  M.refresh()
end
function M.new_worktree()
  vim.ui.input({ prompt = 'New worktree path: ', default = (M.root or '') .. '-', completion = 'dir' },
    function(path)
      if not path or path == '' then return end
      vim.ui.input({ prompt = 'Branch (existing) or new name (blank = detach HEAD): ' }, function(br)
        local args
        if not br or br == '' then args = { 'worktree', 'add', '--', path }
        else args = { 'worktree', 'add', '--', path, br } end
        local ok, res = run(args, { quiet = true })
        if not ok and (res.stderr or ''):match('invalid reference') then
          -- branch doesn't exist: create it
          run({ 'worktree', 'add', '-b', br, '--', path })
        elseif not ok then
          vim.notify('git worktree add:\n' .. chomp(res.stderr), vim.log.levels.ERROR)
        end
        M.refresh()
      end)
    end)
end
function M.remove_worktree()
  local it = cur_item()
  if not (it and it.kind == 'worktree') then
    return vim.notify('GitPanel: move the cursor onto a worktree to remove it', vim.log.levels.INFO)
  end
  if it.current then return vim.notify('GitPanel: cannot remove the current worktree', vim.log.levels.WARN) end
  local pick = fn.confirm('Remove worktree "' .. tilde(it.value) .. '"?', '&Yes\n&No', 2)
  if pick ~= 1 then return end
  local ok, res = run({ 'worktree', 'remove', '--', it.value }, { quiet = true })
  if not ok and (res.stderr or ''):match('use %-%-force') then
    local p2 = fn.confirm('Worktree has changes. Force remove?', '&Yes\n&No', 2)
    if p2 == 1 then run({ 'worktree', 'remove', '--force', '--', it.value }) end
  elseif not ok then
    vim.notify('git worktree remove:\n' .. chomp(res.stderr), vim.log.levels.WARN)
  end
  M.refresh()
end

local function current_branch()
  local res = git({ 'symbolic-ref', '--quiet', '--short', 'HEAD' }, { allow_fail = true })
  if res.code ~= 0 then return nil end
  local branch = chomp(res.stdout)
  return branch ~= '' and branch or nil
end

local function push_branch(remote, branch, remote_was_added)
  local ok, res = run({ 'push', '-u', remote, branch }, { quiet = true })
  if not ok then
    local retained = remote_was_added and
      ('\nRemote "' .. remote .. '" remains configured; fix the error and press P to retry.') or ''
    vim.notify('git push -u ' .. remote .. ' ' .. branch .. ':\n' ..
      chomp(res.stderr) .. retained, vim.log.levels.WARN)
  else
    vim.notify('GitPanel: pushed ' .. branch .. ' to ' .. remote ..
      ' and set its upstream', vim.log.levels.INFO)
  end
  M.refresh()
  return ok
end

-- Git itself can attach and push to a URL, but creating a hosted repository is
-- provider-specific. GitHub's optional `gh` CLI provides that missing API; the
-- URL path remains available for GitLab, Bitbucket, self-hosted Git, and bare
-- repositories created outside the panel.
local function publish_github(branch)
  if fn.executable('gh') ~= 1 then
    return vim.notify('GitPanel: GitHub CLI (gh) is not installed. Install it and run ' ..
      '`gh auth login`, or choose "Attach an existing remote URL".', vim.log.levels.WARN)
  end

  local default_name = fn.fnamemodify(M.root or '', ':t')
  vim.ui.input({
    prompt = 'GitHub repository name (REPO or OWNER/REPO): ',
    default = default_name,
  }, function(repo)
    repo = trim(repo)
    if repo == '' then return end

    local visibilities = {
      { label = 'Private', flag = '--private' },
      { label = 'Public', flag = '--public' },
      { label = 'Internal (GitHub Enterprise)', flag = '--internal' },
    }
    vim.ui.select(visibilities, {
      prompt = 'Repository visibility:',
      format_item = function(item) return item.label end,
    }, function(visibility)
      if not visibility then return end
      local pick = fn.confirm(
        'Create GitHub repository "' .. repo .. '" as ' .. visibility.label:lower() ..
        '?\n\nThis adds remote "origin" and pushes branch "' .. branch .. '".',
        '&Create and push\n&Cancel', 2)
      if pick ~= 1 then return end

      local cmd = {
        'gh', 'repo', 'create', repo, visibility.flag,
        '--source', M.root, '--remote', 'origin', '--push',
      }
      vim.notify('GitPanel: creating ' .. repo .. ' and pushing ' .. branch .. '…',
        vim.log.levels.INFO)
      local res = vim.system(cmd, {
        text = true,
        cwd = M.root,
        env = { LC_ALL = 'C', GH_PROMPT_DISABLED = '1' },
      }):wait()

      if res.code ~= 0 then
        local detail = chomp((res.stderr or '') .. (res.stdout or ''))
        local origin = git({ 'remote', 'get-url', 'origin' }, { allow_fail = true })
        local partial = ''
        if origin.code == 0 then
          partial = '\n\norigin is now ' .. chomp(origin.stdout) ..
            '. The repository may already exist; fix the error and press P to retry the push.'
        end
        vim.notify('gh repo create failed:\n' .. detail .. partial, vim.log.levels.ERROR)
        M.refresh()
        return
      end

      -- gh normally establishes tracking with --push. Keep that invariant
      -- explicit in case a CLI/version leaves only the remote ref behind.
      local upstream = git({ 'rev-parse', '--verify', '--quiet', '@{upstream}' },
        { allow_fail = true })
      if upstream.code ~= 0 then
        local tracked = git({ 'branch', '--set-upstream-to=origin/' .. branch,
          '--', branch }, { allow_fail = true })
        if tracked.code ~= 0 then
          vim.notify('GitPanel: repository was created and pushed, but upstream tracking ' ..
            'could not be set:\n' .. chomp(tracked.stderr), vim.log.levels.WARN)
          M.refresh()
          return
        end
      end

      local url = chomp(res.stdout)
      vim.notify('GitPanel: created ' .. repo .. ' and pushed ' .. branch ..
        (url ~= '' and ('\n' .. url) or ''), vim.log.levels.INFO)
      M.refresh()
    end)
  end)
end

local function attach_remote_url(branch)
  vim.ui.input({ prompt = 'Remote URL to add as origin: ' }, function(url)
    url = trim(url)
    if url == '' then return end
    local ok, res = run({ 'remote', 'add', 'origin', url }, { quiet = true })
    if not ok then
      vim.notify('git remote add origin:\n' .. chomp(res.stderr), vim.log.levels.ERROR)
      M.refresh()
      return
    end
    push_branch('origin', branch, true)
  end)
end

function M.publish()
  if #remote_names() > 0 then return M.push() end

  local branch = current_branch()
  if not branch then
    return vim.notify('GitPanel: cannot publish a detached HEAD; switch to a branch first',
      vim.log.levels.WARN)
  end
  local head = git({ 'rev-parse', '--verify', '--quiet', 'HEAD' }, { allow_fail = true })
  if head.code ~= 0 then
    return vim.notify('GitPanel: create at least one commit before publishing this repository',
      vim.log.levels.INFO)
  end

  local gh_available = fn.executable('gh') == 1
  local choices = {
    { id = 'github', label = 'Create a new GitHub repository' ..
      (gh_available and '' or ' (gh not installed)') },
    { id = 'url', label = 'Attach an existing remote URL' },
  }
  vim.ui.select(choices, {
    prompt = 'No Git remote is configured. Publish how?',
    format_item = function(item) return item.label end,
  }, function(choice)
    if not choice then return end
    if choice.id == 'github' then publish_github(branch)
    else attach_remote_url(branch) end
  end)
end

function M.push()
  local remotes = remote_names()
  if #remotes == 0 then return M.publish() end

  local branch = current_branch()
  if not branch then
    return vim.notify('GitPanel: cannot push a detached HEAD; switch to a branch first',
      vim.log.levels.WARN)
  end

  local upstream = git({ 'rev-parse', '--verify', '--quiet', '@{upstream}' },
    { allow_fail = true })
  if upstream.code == 0 then
    local ok, res = run({ 'push' }, { quiet = true })
    if not ok then vim.notify('git push:\n' .. chomp(res.stderr), vim.log.levels.WARN) end
    M.refresh()
    return
  end

  if #remotes == 1 then return push_branch(remotes[1], branch) end
  vim.ui.select(remotes, { prompt = 'Push "' .. branch .. '" to remote:' }, function(remote)
    if remote then push_branch(remote, branch) end
  end)
end
function M.pull() run({ 'pull', '--ff-only' }); M.refresh() end
function M.fetch() run({ 'fetch', '--all', '--prune' }); M.refresh() end

local HELP = {
  'Git Panel — keys',
  '',
  '  <Tab>   switch Changes view (Staged/Unstaged <-> Committed/Uncommitted)',
  '  <CR>    act on item: section->fold, branch->checkout, worktree->switch,',
  '          file->open, commit->show, push->show its commits',
  '  za      fold / unfold section under cursor',
  '',
  '  s / u   stage / unstage file under cursor',
  '  S / U   Stage All / Unstage All',
  '  x       discard changes to file under cursor (confirm)',
  '',
  '  Conflicts (during a merge / rebase / cherry-pick / revert):',
  '  <CR>    open the conflicted file at the first <<<<<<< marker',
  '  o / t   resolve file under cursor: take ours / take theirs (then staged)',
  '          (note: git inverts ours/theirs during a rebase — see the banner)',
  '  s       mark the file resolved (git add) after editing it by hand',
  '  >       continue / finish the operation (<op> --continue)',
  '  A       abort the whole operation (confirm)',
  '',
  '  c       commit staged       C   Commit All (stage everything + commit)',
  '  a       amend last commit',
  '',
  '  <CR>    (on a branch) checkout      b   new branch',
  '  R       rename branch (choose local only, remote only, or both)',
  '          remote default/protected branches may require a host setting change',
  '  m       merge branch under cursor into current',
  '  d       delete branch / remove worktree (context-sensitive)',
  '  W       new worktree',
  '',
  '  F / P   pull (--ff-only) / push (publish if no remote)',
  '  f       fetch --all --prune',
  '  L       toggle layout (full tab <-> left split)',
  '  r       refresh    g? / ?  this help    q   close',
}
function M.help()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, HELP)
  api.nvim_set_option_value('modifiable', false, { buf = buf })
  local width, height = 76, #HELP + 2
  local win = api.nvim_open_win(buf, true, {
    relative = 'editor', style = 'minimal', border = 'rounded',
    width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  })
  api.nvim_set_option_value('cursorline', false, { win = win })
  vim.keymap.set('n', 'q', '<cmd>close<cr>', { buffer = buf, nowait = true, silent = true })
  vim.keymap.set('n', '<esc>', '<cmd>close<cr>', { buffer = buf, nowait = true, silent = true })
end

function M.attach_keys()
  local buf = M.buf
  local function k(lhs, fnc, desc)
    vim.keymap.set('n', lhs, fnc, { buffer = buf, nowait = true, silent = true, desc = 'GitPanel: ' .. desc })
  end
  -- Some terminals/SSH paths encode the Enter key as LF or keypad Enter.
  -- Keep these mappings buffer-local: ordinary editing buffers retain their
  -- normal Enter motions, while every terminal representation works here.
  for _, lhs in ipairs({ '<CR>', '<NL>', '<kEnter>' }) do
    k(lhs, M.primary, 'primary action')
  end
  k('<Tab>', M.toggle_view, 'switch Changes view')
  k('za', M.toggle_fold, 'fold/unfold section')
  k('s', M.stage, 'stage file')
  k('u', M.unstage, 'unstage file')
  k('S', M.stage_all, 'Stage All')
  k('U', M.unstage_all, 'Unstage All')
  k('x', M.discard, 'discard file (confirm)')
  k('o', M.resolve_ours, 'resolve conflict: take ours')
  k('t', M.resolve_theirs, 'resolve conflict: take theirs')
  k('>', M.op_continue, 'continue merge/rebase/cherry-pick')
  k('A', M.op_abort, 'abort merge/rebase/cherry-pick')
  k('c', M.commit, 'commit staged')
  k('C', M.commit_all, 'Commit All')
  k('a', M.amend, 'amend')
  k('b', M.new_branch, 'new branch')
  k('R', M.rename_branch, 'rename branch (local / remote)')
  k('m', M.merge, 'merge branch into current')
  k('d', function()
    local it = cur_item()
    if it and it.kind == 'worktree' then M.remove_worktree() else M.delete_branch() end
  end, 'delete branch / remove worktree')
  k('W', M.new_worktree, 'new worktree')
  k('P', M.push, 'push / publish repository')
  k('F', M.pull, 'pull (--ff-only)')
  k('f', M.fetch, 'fetch')
  k('L', M.toggle_layout, 'toggle tab/split')
  k('r', M.refresh, 'refresh')
  k('q', M.close, 'close panel')
  k('g?', M.help, 'help')
  k('?', M.help, 'help')
end

-- startup wiring
define_hl()
api.nvim_create_autocmd('ColorScheme', {
  group = api.nvim_create_augroup('GitPanelHl', { clear = true }),
  callback = define_hl,
})

return M
