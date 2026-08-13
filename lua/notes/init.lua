-- Reading the specs agents write, without leaving the view you are in.
--
-- The problem this solves: agents write specs and ledgers to ~/notes/, and the
-- moment you want to read one you are usually sitting in the agent view -- a
-- full-window Claude terminal in its own tabpage (lua/agent/view.lua). Opening
-- the file the obvious way means leaving that view, or worse, a new Ghostty tab
-- and a second editor with no idea about this worktree.
--
-- So: a float. It draws *over* whatever is underneath, agent included, which is
-- the one placement that does not disturb the agent view's deliberate `only`
-- layout and behaves identically from the code view. Close it and you are back
-- exactly where you were, in insert mode if that is where you came from.
--
-- The buffer in the float is the real file, not a scratch copy -- annotate an
-- agent's spec and `:w` lands it, which is the point when you are reviewing one
-- before approving it.
--
-- ---------------------------------------------------------------------------
-- CONFIGURING IT
-- ---------------------------------------------------------------------------
-- Where notes live and what counts as what is all in M.config, overridable from
-- init.lua:
--
--   require('notes').setup {
--     dirs = { '~/notes', '~/work/specs' },
--     groups = { spec = { '*spec*.md', '*-design.md' } },
--   }
--
-- $NOTES_DIR overrides the default directory without touching the config, for
-- the case where a machine keeps them somewhere else.

local M = {}

local uv = vim.uv or vim.loop

M.config = {
  -- Searched in order; every match from every directory ends up in one list,
  -- sorted by mtime rather than by directory, because "which one did the agent
  -- just write" is the question being asked.
  dirs = { vim.env.NOTES_DIR or '~/notes' },

  -- Named sets of globs. A group name is what `:Notes <name>` and the keymaps
  -- take; anything not in this table is treated as a literal glob, so
  -- `:Notes *gitlab*.md` works without adding a group for it.
  groups = {
    spec = { '*spec*.md', '*-requirements*.md', '*-design*.md' },
    ledger = { '*ledger*.md' },
    tasks = { '*tasks*.md', 'handoff-*.md' },
    all = { '*.md', '*.markdown', '*.txt' },
  },

  -- Fractions of the editor. Deliberately not full-screen: the sliver of agent
  -- output around the edge is what tells you the float is an overlay and the
  -- session underneath is still there.
  float = {
    width = 0.82,
    height = 0.86,
    border = 'rounded',
  },
}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local state = {
  win = nil, -- the float, while it is open
  buf = nil, -- buffer shown in it (a real file buffer)
  origin_win = nil, -- where to put the cursor back
  origin_term = false, -- ...and whether to re-enter insert mode there
  last = nil, -- last note opened, for reopen-without-picking
}

local function win_valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- Remember where we were called from, so closing the float can put us back.
---
--- Captured at the keymap rather than at open time: the picker steals focus in
--- between, and by then the terminal window is no longer current.
local function remember_origin()
  if state.win and vim.api.nvim_get_current_win() == state.win then
    return -- already in the float; whatever we recorded before still holds
  end
  local win = vim.api.nvim_get_current_win()
  state.origin_win = win
  state.origin_term = vim.bo[vim.api.nvim_win_get_buf(win)].buftype == 'terminal'
end

---------------------------------------------------------------------------
-- Finding notes
---------------------------------------------------------------------------

--- Compact age -- "3m", "2h", "4d". The list is sorted newest-first anyway, but
--- with several agents writing at once the ordering alone does not tell you
--- whether the top entry is from this minute or from last Tuesday.
local function age(mtime)
  local secs = os.time() - mtime
  if secs < 60 then
    return secs .. 's'
  elseif secs < 3600 then
    return math.floor(secs / 60) .. 'm'
  elseif secs < 86400 then
    return math.floor(secs / 3600) .. 'h'
  end
  return math.floor(secs / 86400) .. 'd'
end

local function patterns_for(group)
  local named = M.config.groups[group]
  if named then
    return named
  end
  -- Not a group name: the caller passed a glob directly.
  return { group }
end

--- Every file matching `group`, newest first.
---@return table[] entries { path, name, dir, mtime }
local function collect(group)
  local seen, out = {}, {}

  for _, dir in ipairs(M.config.dirs) do
    local root = vim.fn.expand(dir)
    for _, pattern in ipairs(patterns_for(group)) do
      -- Both the flat case and any subdirectory, since notes accumulate into
      -- folders eventually and a spec hidden one level down should still list.
      for _, glob in ipairs { pattern, '**/' .. pattern } do
        for _, path in ipairs(vim.fn.globpath(root, glob, false, true)) do
          local stat = not seen[path] and uv.fs_stat(path)
          if stat and stat.type == 'file' then
            seen[path] = true
            out[#out + 1] = {
              path = path,
              name = vim.fn.fnamemodify(path, ':t'),
              dir = vim.fn.fnamemodify(path, ':h'),
              mtime = stat.mtime.sec,
            }
          end
        end
      end
    end
  end

  table.sort(out, function(a, b)
    return a.mtime > b.mtime
  end)
  return out
end

---------------------------------------------------------------------------
-- The float
---------------------------------------------------------------------------

local function geometry()
  local cfg = M.config.float
  local width = math.floor(vim.o.columns * cfg.width)
  local height = math.floor((vim.o.lines - vim.o.cmdheight - 1) * cfg.height)
  return {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    border = cfg.border,
  }
end

--- Close the float and hand focus back to wherever it was opened from.
function M.close()
  if not win_valid(state.win) then
    state.win = nil
    return
  end

  local buf = state.buf
  vim.api.nvim_win_close(state.win, false)
  state.win = nil

  -- The buffer outlives the window on purpose -- unsaved annotations are still
  -- there next time you open it -- but the reading keymaps must not be, or `q`
  -- stops recording macros in a buffer you later edit normally.
  if buf and vim.api.nvim_buf_is_valid(buf) then
    for _, lhs in ipairs { 'q', '<Esc>' } do
      pcall(vim.keymap.del, 'n', lhs, { buffer = buf })
    end
    if vim.bo[buf].modified then
      vim.notify(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':t') .. ' has unsaved edits (still in the buffer list)', vim.log.levels.WARN)
    end
  end

  if win_valid(state.origin_win) then
    vim.api.nvim_set_current_win(state.origin_win)
    if state.origin_term then
      vim.cmd 'startinsert'
    end
  end
end

--- Open `path` in the float. `lnum`, when given, is where to land -- used by the
--- grep entry point so a content match opens on the matching line.
function M.open(path, lnum)
  if not path or path == '' then
    return
  end
  if win_valid(state.win) then
    M.close()
  end

  -- bufadd + bufload rather than :edit, so the file arrives as an ordinary
  -- listed buffer (filetype detected, LSP/render-markdown attached, :w works)
  -- without touching the window layout underneath.
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true

  local opts = geometry()
  opts.style = 'minimal'
  opts.title = ' ' .. vim.fn.fnamemodify(path, ':t') .. ' '
  opts.title_pos = 'center'
  opts.footer = ' q close · :w saves '
  opts.footer_pos = 'right'

  state.buf = buf
  state.win = vim.api.nvim_open_win(buf, true, opts)
  state.last = path

  -- style='minimal' strips the reading affordances too, so put back the ones
  -- that matter for prose.
  local wo = vim.wo[state.win]
  wo.wrap = true
  wo.linebreak = true
  wo.breakindent = true
  wo.cursorline = true
  wo.conceallevel = 2 -- render-markdown.nvim hides the syntax it renders
  wo.concealcursor = 'nc'
  wo.signcolumn = 'no'

  if lnum then
    pcall(vim.api.nvim_win_set_cursor, state.win, { lnum, 0 })
    vim.cmd 'normal! zz'
  end

  local function map(lhs)
    vim.keymap.set('n', lhs, M.close, { buffer = buf, nowait = true, desc = 'Close the note' })
  end
  map 'q'
  map '<Esc>'

  -- Closed by hand (:q, <C-w>c) rather than through M.close: run the same
  -- teardown so the keymaps do not leak onto the buffer.
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(state.win),
    once = true,
    callback = function()
      if win_valid(state.win) then
        return -- a different window closed; ours is still up
      end
      state.win = nil
      for _, lhs in ipairs { 'q', '<Esc>' } do
        pcall(vim.keymap.del, 'n', lhs, { buffer = buf })
      end
    end,
  })
end

--- Reopen the last note without going through the picker -- the "I closed it,
--- and now I need it again" path, which is most of them.
function M.reopen()
  remember_origin()
  if state.last and uv.fs_stat(state.last) then
    M.open(state.last)
  else
    vim.notify('No note opened yet in this session', vim.log.levels.INFO)
  end
end

---------------------------------------------------------------------------
-- Picking one
---------------------------------------------------------------------------

local function fallback_select(entries, title)
  vim.ui.select(entries, {
    prompt = title,
    format_item = function(e)
      return string.format('%-5s %s', age(e.mtime), e.name)
    end,
  }, function(choice)
    if choice then
      M.open(choice.path)
    end
  end)
end

--- List every note in `group` and open the one you pick.
---
--- Always a list, never "open the newest": with several agents writing at once
--- recency is not a good proxy for the one you meant. The age column is there
--- to help you choose, not to choose for you.
function M.pick(group)
  group = group or 'spec'
  remember_origin()

  local entries = collect(group)
  if #entries == 0 then
    vim.notify(('No %s notes in %s'):format(group, table.concat(M.config.dirs, ', ')), vim.log.levels.WARN)
    return
  end

  local title = group:sub(1, 1):upper() .. group:sub(2) .. ' notes'

  local ok, pickers = pcall(require, 'telescope.pickers')
  if not ok then
    return fallback_select(entries, title)
  end
  local finders = require 'telescope.finders'
  local conf = require('telescope.config').values
  local actions = require 'telescope.actions'
  local action_state = require 'telescope.actions.state'
  local entry_display = require 'telescope.pickers.entry_display'

  local displayer = entry_display.create {
    separator = '  ',
    items = { { width = 5 }, { remaining = true } },
  }

  pickers
    .new({}, {
      prompt_title = title,
      finder = finders.new_table {
        results = entries,
        entry_maker = function(e)
          return {
            value = e,
            path = e.path,
            ordinal = e.name,
            display = function(entry)
              return displayer { { age(entry.value.mtime), 'Comment' }, entry.value.name }
            end,
          }
        end,
      },
      -- Unsorted by default so the mtime order survives an empty prompt; the
      -- fuzzy sorter only kicks in once you type.
      sorter = conf.generic_sorter {},
      previewer = conf.file_previewer {},
      attach_mappings = function(bufnr)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(bufnr)
          if entry then
            M.open(entry.value.path)
          end
        end)
        return true
      end,
    })
    :find()
end

--- Grep across the notes directories, and open the hit in the float on its line.
--- The other half of "which spec was that": by content rather than by filename.
function M.grep()
  remember_origin()

  local ok, builtin = pcall(require, 'telescope.builtin')
  if not ok then
    vim.notify('Telescope is not available', vim.log.levels.WARN)
    return
  end

  local dirs = vim.tbl_map(function(d)
    return vim.fn.expand(d)
  end, M.config.dirs)

  builtin.live_grep {
    prompt_title = 'Grep notes',
    search_dirs = dirs,
    attach_mappings = function(bufnr)
      local actions = require 'telescope.actions'
      local action_state = require 'telescope.actions.state'
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(bufnr)
        if entry then
          M.open(entry.path or entry.filename, entry.lnum)
        end
      end)
      return true
    end,
  }
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

function M.setup(opts)
  -- Stashed outside the module so it survives a hot reload: config.reload drops
  -- lua/notes/ from package.loaded and re-runs setup with no arguments, which
  -- would otherwise silently reset dirs/groups back to the defaults.
  if opts then
    vim.g.notes_opts = opts
  end
  M.config = vim.tbl_deep_extend('force', M.config, vim.g.notes_opts or {})

  local map = vim.keymap.set

  -- <leader>n rather than another <leader>a binding: these are notes about the
  -- work, not the agent's own controls, and <leader>a is already crowded.
  map('n', '<leader>nn', function()
    M.pick 'all'
  end, { desc = 'All notes' })
  map('n', '<leader>ns', function()
    M.pick 'spec'
  end, { desc = 'Specs' })
  map('n', '<leader>nl', function()
    M.pick 'ledger'
  end, { desc = 'Ledgers' })
  map('n', '<leader>nt', function()
    M.pick 'tasks'
  end, { desc = 'Tasks / handoffs' })
  map('n', '<leader>nr', M.reopen, { desc = 'Reopen the last note' })
  map('n', '<leader>n/', M.grep, { desc = 'Grep notes' })

  -- The binding that makes this worth having: reachable from inside the agent
  -- terminal without first dropping out of terminal mode. <C-g> is unbound in
  -- Claude's TUI; if that ever changes, this line is the only thing to edit.
  map('t', '<C-g>', function()
    remember_origin()
    vim.cmd 'stopinsert'
    vim.schedule(function()
      M.pick 'spec'
    end)
  end, { desc = 'Specs (from the agent view)' })

  vim.api.nvim_create_user_command('Notes', function(cmd)
    M.pick(cmd.args ~= '' and cmd.args or 'spec')
  end, {
    nargs = '?',
    complete = function(lead)
      return vim.tbl_filter(function(name)
        return name:find(lead, 1, true) == 1
      end, vim.tbl_keys(M.config.groups))
    end,
    desc = 'Pick a note to read (group name or glob)',
  })

  -- Keep the float centred when the terminal is resized, rather than leaving it
  -- clipped off the edge.
  vim.api.nvim_create_autocmd('VimResized', {
    group = vim.api.nvim_create_augroup('notes_float', { clear = true }),
    callback = function()
      if win_valid(state.win) then
        vim.api.nvim_win_set_config(state.win, geometry())
      end
    end,
  })
end

return M
