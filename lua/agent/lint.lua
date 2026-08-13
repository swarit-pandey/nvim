-- Fix the current buffer's diagnostics with Claude, without leaving the buffer.
--
-- Runs `claude -p` as a background process rather than driving the interactive
-- pane. That buys three things:
--   * no window opens and focus never moves
--   * the process exits on its own, so there is no session to clean up, and your
--     interactive agent session (and its model) is left completely alone
--   * tool access can be locked down with real CLI flags instead of politely
--     worded prompt rules
--
-- Nothing is silently trusted: the file is snapshotted first, and when the run
-- finishes you get a diff of exactly what changed, to accept or reject per hunk.
--
-- SWAPPING AGENTS: `build_command()` is the only agent-specific part. See the
-- "Swapping in another agent" note at the top of lua/agent/view.lua.

local M = {}

local devlog = require 'config.devlog'
local progress = require 'agent.progress'

M.config = {
  -- Diagnostics are mechanical single-file edits, so a mid-tier model is the
  -- right tool. This is a separate process from the interactive session, so it
  -- does not disturb whatever model that is using.
  model = 'sonnet',

  -- Every severity, hints included. Hints are not just style noise: gopls ships
  -- its whole `modernize` analyzer at HINT level ("for loop can be modernized
  -- using range over int"), and TypeScript reports unused symbols the same way.
  -- Those are exactly the safe single-file edits this is for.
  --
  -- Set to `{ min = vim.diagnostic.severity.WARN }` to get only real problems.
  severity = nil,

  -- Read and Edit only: no Bash (so it cannot run builds or tests), no Write
  -- (so it cannot create files).
  --
  -- This is `--tools`, not `--allowed-tools`. The latter is an auto-approve list
  -- and does NOT restrict: with it set to "Read,Edit" the agent still shelled out
  -- to `find`. With `--tools` it reports having no shell tool at all. Verified.
  tools = 'Read,Edit',

  -- Narrate the run in a side pane instead of going silent and then dropping a
  -- diff on you unannounced.
  show_progress = true,

  timeout_ms = 180000,

  -- Dropped before Claude ever sees them, matched against the message. These
  -- either cannot be fixed inside one file, or their "fix" is a dependency
  -- change.
  skip_patterns = {
    'deprecat', -- migrating off a deprecated API is a dependency decision
    'undefined:', -- the symbol lives in another file, or nowhere
    'undeclared name',
    'could not import',
    'cannot find package',
    'no required module provides',
    'has no field or method',
    'is not a type',
  },
}

local SEVERITY = {
  [vim.diagnostic.severity.ERROR] = 'ERROR',
  [vim.diagnostic.severity.WARN] = 'WARN',
  [vim.diagnostic.severity.INFO] = 'INFO',
  [vim.diagnostic.severity.HINT] = 'HINT',
}

M.last_output = nil
local running = false

---------------------------------------------------------------------------
-- Diagnostics -> prompt
---------------------------------------------------------------------------

local function skipped(diagnostic)
  local message = diagnostic.message:lower()
  for _, pattern in ipairs(M.config.skip_patterns) do
    if message:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function format_one(diagnostic)
  local source = diagnostic.source and (' [' .. diagnostic.source .. ']') or ''
  local code = diagnostic.code and (' (' .. tostring(diagnostic.code) .. ')') or ''
  -- Diagnostics are 0-indexed internally; everyone talks in 1-indexed lines.
  return string.format(
    '  L%d:%d %s%s%s %s',
    diagnostic.lnum + 1,
    diagnostic.col + 1,
    SEVERITY[diagnostic.severity] or '?',
    source,
    code,
    (diagnostic.message:gsub('%s*\n%s*', ' '))
  )
end

local function build_prompt(path, entries)
  return table.concat({
    'Fix these static analysis diagnostics in a single file.',
    '',
    'File: ' .. path,
    '',
    'Hard rules -- follow these over any instinct to be helpful:',
    '1. Edit ONLY `' .. path .. '`. Touch no other file.',
    '2. You can import libraries to fix diagnostics errors.',
    '3. Fix only what can be fixed entirely inside this file. If a diagnostic',
    '   needs a change elsewhere -- a missing symbol, a signature owned by another',
    '   package, a type defined in another file -- leave it alone.',
    '4. Do not migrate off deprecated APIs, and do not change dependency versions.',
    '5. Do not refactor, rename, reformat or otherwise improve anything not',
    '   required by a diagnostic below. A formatter already runs on save.',
    '6. If a diagnostic is a false positive or the fix is not obvious, skip it.',
    '7. If fixing a diagnostic requires you to modify/edit files other than the specified path - you SHOULD NOT PROCEED',
    '',
    'Reply with one short line per diagnostic: fixed, or skipped and why.',
    '',
    'Diagnostics:',
    table.concat(entries, '\n'),
  }, '\n')
end

--- Selected code is included verbatim as context, not as the thing being
--- pattern-matched against -- unlike diagnostics, the instruction is free text
--- and may legitimately require touching lines outside the selection.
local function build_selection_prompt(path, start_line, end_line, code, instruction)
  return table.concat({
    'Apply the instruction below to a single file.',
    '',
    'File: ' .. path,
    ('Selected lines %d-%d, included below for context:'):format(start_line, end_line),
    '```',
    code,
    '```',
    '',
    'Instruction: ' .. instruction,
    '',
    'First decide which kind of instruction that is:',
    '',
    'If it asks a QUESTION or asks you to explain, describe or review something,',
    'then answer it and make NO edits at all. Do not add comments or docstrings to',
    'convey the answer -- the answer is the reply, not a change to the file.',
    'Write the reply in markdown: a short heading, bullets, `inline code` for',
    'identifiers, fenced blocks for snippets.',
    '',
    'Otherwise apply it, under these hard rules -- follow them over any instinct',
    'to be helpful:',
    '1. Edit ONLY `' .. path .. '`. Touch no other file.',
    '2. Do NOT add any new import, package, module or dependency unless the',
    '   instruction explicitly asks for one.',
    '3. Do not refactor, rename, reformat or otherwise change anything the',
    '   instruction did not ask for.',
    'Then reply with a short summary of what you changed.',
  }, '\n')
end

---------------------------------------------------------------------------
-- Running
---------------------------------------------------------------------------

--- SWAP POINT: the agent invocation. Any CLI that can take a prompt, edit files
--- in place and exit will drop in here.
local function build_command(prompt)
  local cmd = { 'claude', '-p', prompt }
  if M.config.model then
    vim.list_extend(cmd, { '--model', M.config.model })
  end
  if M.config.tools then
    vim.list_extend(cmd, { '--tools', M.config.tools })
  end
  -- Edits land on disk unprompted; that is the point. The snapshot diff is what
  -- makes it safe, not a confirmation dialog.
  --
  -- stream-json rather than json so the side pane can narrate as it goes;
  -- --verbose is required for it.
  vim.list_extend(cmd, { '--permission-mode', 'acceptEdits', '--output-format', 'stream-json', '--verbose' })
  return cmd
end

--- Set of paths git currently reports as dirty, so we can spot the agent
--- straying outside the file it was told to touch.
local function dirty_set(root)
  if not root then
    return nil
  end
  local out = vim.system({ 'git', '-C', root, 'status', '--porcelain' }, { text = true }):wait()
  if out.code ~= 0 then
    return nil
  end
  local set = {}
  for line in (out.stdout or ''):gmatch '[^\n]+' do
    set[line:sub(4)] = true
  end
  return set
end

local function report_strays(root, before, target)
  local after = dirty_set(root)
  if not before or not after then
    return
  end
  local strays = {}
  for path in pairs(after) do
    if not before[path] and path ~= target then
      table.insert(strays, path)
    end
  end
  if #strays > 0 then
    table.sort(strays)
    vim.notify('Claude also changed: ' .. table.concat(strays, ', ') .. '\nReview with <leader>gv', vim.log.levels.WARN)
  end
end

--- Where to run the agent. Not every project is a git repo -- a scratch Go
--- module has only go.mod -- and falling back to Neovim's cwd would send a
--- relative path that means nothing from the agent's working directory.
local function project_root(bufnr)
  local markers = { '.git', 'go.mod', 'package.json', 'Cargo.toml', 'pyproject.toml', 'go.work' }
  return vim.fs.root(bufnr, markers) or vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr))
end

local function run(bufnr, root, path, prompt, description)
  local file = vim.api.nvim_buf_get_name(bufnr)

  -- Snapshot before anything is touched; this is the "reject" side of the diff.
  -- Held in memory, not written to disk -- see agent.diff._snapshots.
  local ok_read, snapshot = pcall(vim.fn.readfile, file)
  if not ok_read then
    vim.notify('Could not read the file; aborting', vim.log.levels.ERROR)
    return
  end

  local before = dirty_set(root)
  running = true

  local command = build_command(prompt)
  local started = vim.uv.now()
  devlog.write('FIX', ('start root=%s file=%s task=%s'):format(root, path, description))
  devlog.write('PROMPT', prompt)

  local pane
  if M.config.show_progress then
    pane = progress.open(description)
    progress.append(pane, '  starting ' .. (M.config.model or 'default') .. '…', 'Comment')
  end

  -- stream-json emits one JSON object per line, but process chunks split
  -- wherever they like, so hold the tail until a newline completes it.
  local carry = ''
  local final = nil

  local function consume(chunk)
    carry = carry .. chunk
    while true do
      local nl = carry:find('\n', 1, true)
      if not nl then
        break
      end
      local line = carry:sub(1, nl - 1)
      carry = carry:sub(nl + 1)
      if line ~= '' then
        local ok, event = pcall(vim.json.decode, line)
        if ok and type(event) == 'table' and event.type == 'result' then
          final = event.result
        end
        local text, hl = progress.describe(line)
        if text and pane then
          progress.append(pane, text, hl)
        end
      end
    end
  end

  local opts = {
    cwd = root,
    text = true,
    timeout = M.config.timeout_ms,
    stdout = function(_, chunk)
      if chunk then
        vim.schedule(function()
          consume(chunk)
        end)
      end
    end,
  }

  vim.system(command, opts, function(result)
    vim.schedule(function()
      running = false
      devlog.write('FIX', ('exit=%s after %dms'):format(tostring(result.code), vim.uv.now() - started))
      if result.stderr and result.stderr ~= '' then
        devlog.write('FIX-ERR', result.stderr)
      end

      M.last_output = final or result.stderr or '(no output)'
      devlog.write('FIX-OUT', M.last_output)

      if result.code ~= 0 then
        if pane then
          progress.append(pane, '  failed (exit ' .. tostring(result.code) .. ')', 'DiffDelete')
        end
        vim.notify('Claude exited ' .. result.code .. '. :ClaudeFixLog for details', vim.log.levels.ERROR)
        return
      end

      if not vim.api.nvim_buf_is_valid(bufnr) then
        progress.close(pane)
        return
      end

      -- Pull the agent's on-disk edits into the buffer.
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd 'silent! edit!'
      end)

      report_strays(root, before, path)

      if vim.deep_equal(vim.fn.readfile(file), snapshot) then
        -- No edits means the reply *is* the result -- an explanation, or a
        -- refusal. Show it rather than leaving it behind a command you have to
        -- remember.
        progress.close(pane)
        if M.last_output and M.last_output ~= '' and M.last_output ~= '(no output)' then
          M.show_response('reply', M.last_output)
        else
          vim.notify('Claude made no changes and said nothing', vim.log.levels.WARN)
        end
        return
      end

      -- The pane has done its job; the diff needs the width.
      progress.close(pane)
      require('agent.diff').review(bufnr, snapshot, path)
    end)
  end)
end

---------------------------------------------------------------------------
-- Entry points
---------------------------------------------------------------------------

local function dispatch(bufnr, diagnostics, label)
  if running then
    vim.notify('A fix is already running', vim.log.levels.WARN)
    return
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' then
    vim.notify('This buffer has no file on disk', vim.log.levels.WARN)
    return
  end

  local entries, dropped = {}, 0
  table.sort(diagnostics, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    return a.col < b.col
  end)
  for _, diagnostic in ipairs(diagnostics) do
    if skipped(diagnostic) then
      dropped = dropped + 1
    else
      table.insert(entries, format_one(diagnostic))
    end
  end

  if #entries == 0 then
    local why = dropped > 0 and (' (%d skipped as cross-file or deprecation)'):format(dropped) or ''
    vim.notify('Nothing to fix in this ' .. label .. why, vim.log.levels.INFO)
    -- Log why nothing matched: almost always a severity filter or a skip pattern.
    devlog.write(
      'FIX',
      ('nothing to send: %d raw, %d dropped by skip_patterns, severity filter=%s'):format(#diagnostics, dropped, vim.inspect(M.config.severity))
    )
    return
  end

  -- The agent edits the file on disk, so unsaved work would be clobbered.
  if vim.bo[bufnr].modified then
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd 'write'
    end)
  end

  -- Relative to the agent's working directory, not Neovim's.
  local root = project_root(bufnr)
  local path = vim.fs.relpath(root, name) or vim.fn.fnamemodify(name, ':t')
  local description = ('fixing %d diagnostic%s in %s'):format(#entries, #entries == 1 and '' or 's', path)
  run(bufnr, root, path, build_prompt(path, entries), description)
end

--- `vim.diagnostic.get` treats a nil filter table as "no filter", but passing
--- `{ severity = nil }` is not the same as passing nothing in all versions, so
--- build the filter explicitly.
local function query(bufnr, extra)
  local filter = vim.tbl_extend('force', {}, extra or {})
  if M.config.severity then
    filter.severity = M.config.severity
  end
  return vim.diagnostic.get(bufnr, filter)
end

function M.buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  dispatch(bufnr, query(bufnr), 'buffer')
end

function M.line()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1
  dispatch(bufnr, query(bufnr, { lnum = lnum }), 'line')
end

--- Run an agent on a visual selection with a free-text instruction, using the
--- same snapshot/spawn/diff engine as M.buffer/M.line. Unlike those, this isn't
--- diagnostic-driven -- the selected code is just context for whatever the
--- instruction asks for.
function M.selection()
  if running then
    vim.notify('A fix is already running', vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' then
    vim.notify('This buffer has no file on disk', vim.log.levels.WARN)
    return
  end

  -- Leaving visual mode is what makes Neovim write the '< '> marks for *this*
  -- selection -- reading them any earlier would get whatever was selected last.
  vim.cmd 'normal! \27'
  local start_line = vim.fn.line "'<"
  local end_line = vim.fn.line "'>"
  local code = table.concat(vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false), '\n')

  vim.ui.input({ prompt = 'Agent instruction: ' }, function(instruction)
    if not instruction or instruction == '' then
      return
    end

    -- The agent edits the file on disk, so unsaved work would be clobbered.
    if vim.bo[bufnr].modified then
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd 'write'
      end)
    end

    -- Relative to the agent's working directory, not Neovim's.
    local root = project_root(bufnr)
    local path = vim.fs.relpath(root, name) or vim.fn.fnamemodify(name, ':t')
    local prompt = build_selection_prompt(path, start_line, end_line, code, instruction)
    -- Neutral wording: the instruction may be a question, not an edit.
    local description = ('lines %d-%d of %s'):format(start_line, end_line, path)
    run(bufnr, root, path, prompt, description)
  end)
end

--- Show a reply in its own buffer, as markdown.
---
--- Claude answers in markdown -- headings, lists, fenced code. Rendering it
--- properly matters most for the explain-style requests that produce no edits at
--- all, where the reply *is* the whole result. filetype=markdown is what wakes up
--- render-markdown.nvim; wrap and linebreak are what make prose readable in a
--- split.
---@param title string
---@param text string
function M.show_response(title, text)
  vim.cmd 'vertical rightbelow split'
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(win, math.max(math.floor(vim.o.columns * 0.42), 60))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n', { plain = true }))

  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'markdown'
  pcall(vim.api.nvim_buf_set_name, buf, title)

  local wo = vim.wo[win]
  wo.wrap = true
  wo.linebreak = true
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  wo.colorcolumn = ''
  wo.cursorline = false
  wo.winbar = '%#DiffText# CLAUDE %#Normal# ' .. title .. '   %#Comment#q close'

  vim.keymap.set('n', 'q', '<cmd>close<CR>', { buffer = buf, nowait = true, desc = 'Close' })
end

--- What Claude said it did -- the part you'd otherwise read in the chat pane.
function M.log()
  if not M.last_output then
    vim.notify('No fix has run yet', vim.log.levels.INFO)
    return
  end
  M.show_response('last reply', M.last_output)
end

function M.setup()
  vim.keymap.set('n', '<leader>ax', M.buffer, { desc = 'Fix diagnostics in this buffer' })
  vim.keymap.set('n', '<leader>al', M.line, { desc = 'Fix diagnostic on this line' })
  vim.keymap.set('n', '<leader>aL', M.log, { desc = "Show Claude's last fix log" })
  vim.keymap.set('v', '<leader>ae', M.selection, { desc = 'Run an agent on the selected lines' })

  vim.api.nvim_create_user_command('ClaudeFixBuffer', M.buffer, { desc = "Fix this buffer's diagnostics" })
  vim.api.nvim_create_user_command('ClaudeFixLine', M.line, { desc = 'Fix the diagnostic on this line' })
  vim.api.nvim_create_user_command('ClaudeFixLog', M.log, { desc = 'Show the last fix log' })
  vim.api.nvim_create_user_command('ClaudeEditSelection', M.selection, { desc = 'Run an agent on the selected lines' })
end

return M
