-- Make Claude's proposal diff reviewable hunk by hunk.
--
-- claudecode.nvim presents a proposal as a native Vim diff and -- importantly --
-- leaves the proposed buffer `modifiable`. Accepting writes whatever that buffer
-- currently contains, not Claude's original text. So partial acceptance already
-- works: revert the hunks you don't want with `:diffget`, then accept the rest.
--
-- That is entirely undiscoverable, which is all this module fixes: a winbar
-- spelling out the keys, and a memorable binding for the per-hunk revert.

local M = {}

--- claudecode.nvim tags its proposal buffers with this.
local function is_proposal(bufnr)
  return vim.b[bufnr].claudecode_diff_tab_name ~= nil
end

--- Spelled out in hints rather than "<leader>", which is both longer and less
--- informative than the key you actually press.
local leader = vim.g.mapleader == ' ' and '␣' or (vim.g.mapleader or '\\')

--- Rendered via a `%{%...%}` expression so it re-evaluates per redraw and simply
--- disappears if the window later shows something else. Setting a static string
--- would leave the hint stuck on an unrelated buffer.
--- Adapts to the window width. A review sits in a vertical split, so the full
--- hint does not fit and a fixed string truncates mid-word into nonsense like
--- "<c hunk". Each tier drops the least useful part first.
function M.winbar()
  local bufnr = vim.api.nvim_get_current_buf()

  if vim.b[bufnr].agent_review_side then
    return '%#Folded# BEFORE %#Comment# reference only '
  end

  local title
  if is_proposal(bufnr) then
    title = 'PROPOSAL'
  elseif M._snapshots[bufnr] then
    title = 'CHANGES'
  else
    return ''
  end

  local width = vim.api.nvim_win_get_width(0)
  local label = '%#DiffText# ' .. title .. ' %#Normal# '

  if width >= 74 then
    return label
      .. table.concat {
        '%#Comment#]c%#Normal# next  ',
        '%#Comment#' .. leader .. 'ah%#Normal# reject  ',
        '%#Comment#' .. leader .. 'aa%#Normal# keep  ',
        '%#Comment#' .. leader .. 'ad%#Normal# revert all',
      }
  elseif width >= 44 then
    return label .. '%#Comment#]c%#Normal# next  %#Comment#ah%#Normal# reject  %#Comment#aa%#Normal# keep'
  end
  return label
end

---------------------------------------------------------------------------
-- Diff chrome
---------------------------------------------------------------------------

--- Strip the window decoration that competes with a diff, and restore it after.
---
--- Relative numbers are actively misleading side by side: each pane counts from
--- its own cursor, so the same source line shows two different numbers. On top of
--- that, cursorline, colorcolumn and the fold gutter all draw highlights over the
--- ones actually carrying meaning.
---
--- Driven by window events rather than `OptionSet`, because `OptionSet` does not
--- fire for `diff` -- `:diffthis` sets it internally and skips the trigger
--- (verified: zero events). Everything that opens a diff, including diffview and
--- claudecode's proposals, goes through a window enter, so this catches them all.
function M.chrome(win)
  win = win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local wo = vim.wo[win]

  if wo.diff then
    if vim.w[win].pre_diff == nil then
      vim.w[win].pre_diff = {
        relativenumber = wo.relativenumber,
        cursorline = wo.cursorline,
        colorcolumn = wo.colorcolumn,
        list = wo.list,
      }
    end
    wo.relativenumber = false
    wo.cursorline = false
    wo.colorcolumn = ''
    wo.foldcolumn = '0'
    wo.list = false
    wo.foldtext = 'v:lua.require("agent.diff").foldtext()'
  elseif vim.w[win].pre_diff ~= nil then
    local saved = vim.w[win].pre_diff
    wo.relativenumber = saved.relativenumber
    wo.cursorline = saved.cursorline
    wo.colorcolumn = saved.colorcolumn
    wo.list = saved.list
    -- Restored from the global default, not a snapshot: `:diffthis` sets
    -- foldcolumn=2 itself, so by the time we look it has already been changed and
    -- "restoring" it would leave a fold gutter behind that was never there.
    wo.foldcolumn = vim.go.foldcolumn
    wo.foldtext = ''
    vim.w[win].pre_diff = nil
  end
end

--- Diff mode folds the unchanged stretches between hunks. With no fold column
--- that collapse is invisible -- the numbers just jump from 1 to 9 as if lines
--- were missing. Say how many are hidden instead.
function M.foldtext()
  local n = vim.v.foldend - vim.v.foldstart + 1
  return ('  ⋯ %d unchanged lines '):format(n)
end

--- Apply to every window in the current tab, for the case where a diff is set up
--- on a window we are already sitting in and no enter event follows.
function M.chrome_all()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    M.chrome(win)
  end
end

---------------------------------------------------------------------------
-- Review of a background (headless) fix
---------------------------------------------------------------------------

--- Pre-run contents, keyed by buffer. Kept in memory rather than on disk: a real
--- temp file has to be opened as a real buffer, which attaches a language server
--- to it -- and a second copy of the file in the server's view produces
--- fabricated diagnostics ("main redeclared in this block") on both sides.
M._snapshots = {}

--- Diff a buffer the agent has already edited against its pre-run snapshot.
---
--- Unlike the in-flight proposal the edits are already on disk here, so the
--- polarity is reversed: the buffer holds the new version and the snapshot is
--- what you fall back to. `:diffget` therefore still means "reject this hunk".
---@param bufnr integer buffer the agent edited
---@param snapshot string[] pre-run lines
---@param label string display path
function M.review(bufnr, snapshot, label)
  -- 0 conventionally means "current buffer", but it is not a real handle --
  -- `:buffer 0` errors with E939.
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end

  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    vim.cmd('buffer ' .. bufnr)
    win = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_set_current_win(win)

  M._snapshots[bufnr] = snapshot
  vim.cmd 'diffthis'

  -- Scratch buffer, never a file on disk.
  local snap_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(snap_buf, 0, -1, false, snapshot)
  vim.bo[snap_buf].buftype = 'nofile'
  vim.bo[snap_buf].bufhidden = 'wipe'
  vim.bo[snap_buf].modifiable = false
  vim.b[snap_buf].agent_review_side = true
  pcall(vim.api.nvim_buf_set_name, snap_buf, 'BEFORE: ' .. label)

  -- Highlight via treesitter directly instead of setting `filetype`. Setting the
  -- filetype is what triggers LSP attach, and this buffer must stay invisible to
  -- the language server.
  local lang = vim.treesitter.language.get_lang(vim.bo[bufnr].filetype or '')
  if lang then
    pcall(vim.treesitter.start, snap_buf, lang)
  end

  vim.cmd 'vertical leftabove split'
  vim.api.nvim_win_set_buf(0, snap_buf)
  vim.cmd 'diffthis'

  -- Land on the edited side, at the first change. `]c` jumps to the *next*
  -- change, so firing it unconditionally from line 1 skips the first hunk when
  -- the file changed right at the top.
  vim.api.nvim_set_current_win(win)
  M.chrome_all()
  vim.cmd 'normal! gg'
  if vim.fn.diff_hlID(1, 1) <= 0 then
    pcall(vim.cmd, 'normal! ]c')
  end

  local function finish()
    M._snapshots[bufnr] = nil
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.b[b].agent_review_side then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd 'diffoff'
    end)

    -- Unbind the review keys. Left in place they outlive the review: with the
    -- snapshot already cleared, <leader>ad would restore nothing and still
    -- announce "Reverted everything", and all three shadowed claudecode's global
    -- DiffAccept/DiffDeny in this buffer forever.
    for _, lhs in ipairs { '<leader>ah', '<leader>aa', '<leader>ad' } do
      pcall(vim.keymap.del, 'n', lhs, { buffer = bufnr })
    end

    -- Any non-empty winbar value draws the bar, so leaving the expression set
    -- leaves a blank row above every other buffer shown in this window.
    for _, w in ipairs(vim.fn.win_findbuf(bufnr)) do
      if vim.api.nvim_win_is_valid(w) then
        vim.wo[w].winbar = ''
      end
    end

    M.chrome_all()
  end

  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = bufnr, desc = desc })
  end

  map('<leader>ah', function()
    local ok = pcall(vim.cmd, 'diffget')
    vim.notify(ok and 'Hunk rejected' or 'No hunk under the cursor', ok and vim.log.levels.INFO or vim.log.levels.WARN)
  end, 'Reject this hunk')

  map('<leader>aa', function()
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd 'silent write'
    end)
    finish()
    vim.notify 'Kept the remaining changes'
  end, 'Accept and close review')

  map('<leader>ad', function()
    local snap = M._snapshots[bufnr]
    if not snap then
      -- Report what happened. Announcing a revert that did not happen is worse
      -- than doing nothing, because you stop looking.
      finish()
      vim.notify('No snapshot for this buffer; nothing was reverted', vim.log.levels.WARN)
      return
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, snap)
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd 'silent write'
    end)
    finish()
    vim.notify 'Reverted everything'
  end, 'Reject everything and close review')

  vim.notify(('Review: %s  ·  ]c next  ·  <leader>ah reject hunk  ·  <leader>aa keep  ·  <leader>ad revert all'):format(label))
end

function M.setup()
  local group = vim.api.nvim_create_augroup('agent_diff', { clear = true })

  vim.api.nvim_create_autocmd({ 'WinEnter', 'BufWinEnter', 'WinNew', 'TabEnter' }, {
    group = group,
    callback = function()
      M.chrome()
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWinEnter' }, {
    group = group,
    callback = function(ev)
      local tagged = is_proposal(ev.buf) or M._snapshots[ev.buf] ~= nil or vim.b[ev.buf].agent_review_side
      if not tagged then
        return
      end
      vim.wo.winbar = "%{%v:lua.require'agent.diff'.winbar()%}"

      -- The review flow binds its own keys (it needs the snapshot path), so only
      -- the in-flight proposal needs the generic ones.
      if not is_proposal(ev.buf) or vim.b[ev.buf].agent_diff_bound then
        return
      end
      vim.b[ev.buf].agent_diff_bound = true

      local function map(lhs, rhs, desc)
        vim.keymap.set('n', lhs, rhs, { buffer = ev.buf, desc = desc })
      end

      -- `:diffget` with no range pulls the hunk under the cursor from the other
      -- side of the diff -- i.e. restores your original text, dropping just this
      -- one change while leaving the rest of the proposal intact.
      map('<leader>ah', function()
        if not vim.wo.diff then
          vim.notify('Not in a diff', vim.log.levels.WARN)
          return
        end
        local ok, err = pcall(vim.cmd, 'diffget')
        if ok then
          vim.notify 'Hunk rejected (reverted to your version)'
        else
          vim.notify('No hunk under the cursor: ' .. tostring(err), vim.log.levels.WARN)
        end
      end, 'Reject this hunk')

      -- The inverse, for when you rejected one by mistake.
      map('<leader>aH', function()
        pcall(vim.cmd, 'diffput')
        vim.notify 'Hunk restored from proposal'
      end, 'Re-apply this hunk')
    end,
  })
end

return M
