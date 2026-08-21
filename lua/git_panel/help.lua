local api, fn = vim.api, vim.fn

local M = {}

local SECTIONS = {
  {
    title = 'Navigate',
    rows = {
      { keys = { '<Tab>', '<S-Tab>' }, description = 'Move to the next / previous view' },
      { keys = { '1', '2', '3', '4', '5' }, description = 'Jump to Changes, History, Actions, Issues, or Pull Requests' },
      { keys = { '<CR>' }, description = 'Run the primary action for the item under the cursor' },
      { keys = { 'za' }, description = 'Fold or unfold the current section' },
    },
  },
  {
    title = 'Changes',
    rows = {
      { keys = { 's', 'u' }, description = 'Stage / unstage the file under the cursor' },
      { keys = { 'S', 'U' }, description = 'Stage all / unstage all files' },
      { keys = { 'x' }, description = 'Discard the selected file changes after confirmation', warning = true },
    },
  },
  {
    title = 'Conflicts',
    rows = {
      { keys = { '<CR>' }, description = 'Open the file at its first conflict marker' },
      { keys = { 'o', 't' }, description = 'Take ours / theirs, then stage the result' },
      { keys = { 's' }, description = 'Mark a manually edited file as resolved with git add' },
      { keys = { '>' }, description = 'Continue the merge, rebase, cherry-pick, or revert' },
      { keys = { 'A' }, description = 'Abort the whole in-progress operation after confirmation', warning = true },
      { note = 'During a rebase, Git reverses the usual meaning of ours/theirs; follow the panel banner.' },
    },
  },
  {
    title = 'Commits',
    rows = {
      { keys = { 'c', 'C' }, description = 'Commit staged files / stage everything and commit' },
      { keys = { 'a' }, description = 'Amend the latest commit' },
    },
  },
  {
    title = 'Branches & worktrees',
    rows = {
      { keys = { '<CR>' }, description = 'Check out a branch or switch to a worktree' },
      { keys = { 'b', 'R' }, description = 'Create / rename a branch' },
      { keys = { 'm' }, description = 'Merge the selected branch into the current branch' },
      { keys = { 'd' }, description = 'Delete a branch or remove a worktree (context-sensitive)', warning = true },
      { keys = { 'W' }, description = 'Create a worktree' },
    },
  },
  {
    title = 'Remotes',
    rows = {
      { keys = { 'F', 'P' }, description = 'Pull with --ff-only / push (or publish when no remote exists)' },
      { keys = { 'f' }, description = 'Fetch every remote and prune stale refs' },
    },
  },
  {
    title = 'GitHub views',
    rows = {
      { keys = { '<CR>' }, description = 'Open an in-editor summary for a workflow run, issue, or pull request' },
      { keys = { 'gx' }, description = 'Open the selected item on GitHub' },
      { keys = { 'r' }, description = 'Synchronize repository metadata and every GitHub view now' },
      { keys = { 'go', 'gd' }, description = 'Check out / diff the selected pull request against its base' },
      { keys = { 'gc', 'gm' }, description = 'Comment on / merge the selected pull request (merge deletes its branch, after a confirm)' },
      { note = 'Issue and workflow data stay read-only; pull-request writes always confirm first. Local Git views never require network access.' },
    },
  },
  {
    title = 'Panel',
    rows = {
      { keys = { 'L' }, description = 'Toggle the responsive full tab / compact left split' },
      { keys = { 'r' }, description = 'Refresh the concurrent local repository snapshot' },
      { keys = { '?', 'g?' }, description = 'Show this key guide' },
      { note = 'At 120+ columns the tab layout adds a live context rail; move the cursor to preview the selected item.' },
    },
  },
}

local function display_width(text)
  return fn.strdisplaywidth(text)
end

local function wrap_words(text, width)
  width = math.max(8, width)
  local out, current = {}, ''
  for word in text:gmatch('%S+') do
    local candidate = current == '' and word or (current .. ' ' .. word)
    if current ~= '' and display_width(candidate) > width then
      out[#out + 1] = current
      current = word
    else
      current = candidate
    end
  end
  if current ~= '' then out[#out + 1] = current end
  if #out == 0 then out[1] = '' end
  return out
end

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

function M.render(opts)
  opts = opts or {}
  local width = math.max(24, opts.width or 84)
  local key_width = clamp(math.floor(width * 0.29), 16, 25)
  local description_width = math.max(8, width - key_width - 6)
  local lines, highlights = {}, {}

  local function emit(text)
    lines[#lines + 1] = text
    return #lines
  end

  local function span(line, start_col, end_col, group)
    highlights[#highlights + 1] = {
      line = line - 1,
      start_col = start_col,
      end_col = end_col,
      group = group,
    }
  end

  for _, part in ipairs(wrap_words(
      'Every action is buffer-local. Remote views stay read-only and nonblocking.', width - 4)) do
    local intro = emit('  ' .. part)
    span(intro, 0, #lines[intro], 'GitPanelHelpIntro')
  end
  emit('')

  for section_index, section in ipairs(opts.sections or SECTIONS) do
    local heading = '  ' .. section.title .. ' '
    local rule_width = math.max(2, width - display_width(heading))
    local heading_line = emit(heading .. string.rep('─', rule_width))
    span(heading_line, 2, 2 + #section.title, 'GitPanelHelpSection')
    span(heading_line, 2 + #section.title + 1, #lines[heading_line], 'GitPanelHelpRule')

    for _, row in ipairs(section.rows) do
      if row.note then
        local wrapped = wrap_words(row.note, math.max(8, width - 8))
        for _, part in ipairs(wrapped) do
          local note_line = emit('      ' .. part)
          span(note_line, 0, #lines[note_line], 'GitPanelHelpNote')
        end
      else
        local key_text = table.concat(row.keys or {}, ' / ')
        local descriptions = wrap_words(row.description or '', description_width)
        local key_padding = math.max(1, key_width - display_width(key_text))
        local first = emit('    ' .. key_text .. string.rep(' ', key_padding) .. descriptions[1])

        local search_from = 5
        for _, key in ipairs(row.keys or {}) do
          local start_col = lines[first]:find(key, search_from, true)
          if start_col then
            start_col = start_col - 1
            span(first, start_col, start_col + #key,
              row.warning and 'GitPanelHelpWarningKey' or 'GitPanelHelpKey')
            search_from = start_col + #key + 1
          end
        end

        local description_start = 4 + #key_text + key_padding
        span(first, description_start, #lines[first],
          row.warning and 'GitPanelHelpWarning' or 'GitPanelHelpDescription')
        for index = 2, #descriptions do
          local continuation = emit(string.rep(' ', 4 + key_width) .. descriptions[index])
          span(continuation, 4 + key_width, #lines[continuation],
            row.warning and 'GitPanelHelpWarning' or 'GitPanelHelpDescription')
        end
      end
    end

    if section_index < #(opts.sections or SECTIONS) then emit('') end
  end

  emit('')
  for _, part in ipairs(wrap_words('q / <Esc> close · j/k, <C-d>/<C-u> scroll', width - 4)) do
    local footer = emit('  ' .. part)
    span(footer, 0, #lines[footer], 'GitPanelHelpFooter')
  end

  return {
    lines = lines,
    highlights = highlights,
    width = width,
  }
end

function M.open(opts)
  opts = opts or {}
  local available_width = math.max(24, vim.o.columns - 6)
  local width = math.min(opts.max_width or 88, available_width)
  local rendered = M.render({ width = width, sections = opts.sections })
  local available_height = math.max(4, vim.o.lines - 6)
  local height = math.min(#rendered.lines, available_height)

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, rendered.lines)
  api.nvim_set_option_value('buftype', 'nofile', { buf = buf })
  api.nvim_set_option_value('bufhidden', 'wipe', { buf = buf })
  api.nvim_set_option_value('swapfile', false, { buf = buf })
  api.nvim_set_option_value('modifiable', false, { buf = buf })
  api.nvim_set_option_value('filetype', 'gitpanelhelp', { buf = buf })
  pcall(api.nvim_buf_set_name, buf, 'gitpanel://help')

  local win = api.nvim_open_win(buf, true, {
    relative = 'editor',
    style = 'minimal',
    border = opts.border or 'rounded',
    title = {
      { ' Git Panel ', 'GitPanelHelpTitle' },
      { 'Key Guide ', 'GitPanelHelpTitleAccent' },
    },
    title_pos = 'center',
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  })

  api.nvim_set_option_value('cursorline', false, { win = win })
  api.nvim_set_option_value('number', false, { win = win })
  api.nvim_set_option_value('relativenumber', false, { win = win })
  api.nvim_set_option_value('signcolumn', 'no', { win = win })
  api.nvim_set_option_value('wrap', false, { win = win })
  api.nvim_set_option_value('winhighlight',
    'Normal:NormalFloat,FloatBorder:GitPanelHelpBorder,FloatTitle:GitPanelHelpTitle',
    { win = win })

  local namespace = api.nvim_create_namespace('gitpanel-help')
  for _, highlight in ipairs(rendered.highlights) do
    api.nvim_buf_set_extmark(buf, namespace, highlight.line, highlight.start_col, {
      end_col = highlight.end_col,
      hl_group = highlight.group,
    })
  end

  local close = function()
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
  end
  vim.keymap.set('n', 'q', close, { buffer = buf, nowait = true, silent = true, desc = 'Close GitPanel help' })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf, nowait = true, silent = true, desc = 'Close GitPanel help' })

  return buf, win
end

M.sections = SECTIONS

return M
