-- A side pane that narrates a background agent run.
--
-- Without it a headless fix is a notification, a wait, and then a diff appearing
-- unannounced. Watching the agent read and edit makes the result something you
-- were expecting rather than something that happened to you.

local M = {}

local ns = vim.api.nvim_create_namespace 'agent_progress'

---@class Progress
---@field buf integer
---@field win integer

--- Open the pane without stealing the cursor.
---@param title string
---@return Progress
function M.open(title)
  local origin = vim.api.nvim_get_current_win()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'agentprogress'

  vim.cmd 'botright vsplit'
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, 46)

  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  wo.colorcolumn = ''
  wo.cursorline = false
  wo.wrap = true
  wo.linebreak = true
  wo.winfixwidth = true
  wo.winbar = '%#DiffText# CLAUDE %#Normal# ' .. title

  -- Straight back to where you were: this pane is for watching, not working in.
  vim.api.nvim_set_current_win(origin)

  return { buf = buf, win = win }
end

local function alive(p)
  return p and vim.api.nvim_buf_is_valid(p.buf)
end

--- Append a line and keep the newest visible.
---@param p Progress
---@param text string
---@param hl string|nil highlight group for the whole line
function M.append(p, text, hl)
  if not alive(p) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(p.buf, 0, -1, false)
  -- A fresh scratch buffer has one empty line; write over it rather than
  -- leaving a blank first row.
  local at = (#lines == 1 and lines[1] == '') and 0 or #lines

  vim.bo[p.buf].modifiable = true
  vim.api.nvim_buf_set_lines(p.buf, at, at + (at == 0 and 1 or 0), false, { text })
  vim.bo[p.buf].modifiable = false

  if hl then
    vim.api.nvim_buf_set_extmark(p.buf, ns, at, 0, { end_row = at + 1, hl_group = hl, hl_eol = true })
  end

  -- Follow the tail only while the window is unfocused; if you have clicked into
  -- it to read, scrolling out from under you would be rude.
  if vim.api.nvim_win_is_valid(p.win) and vim.api.nvim_get_current_win() ~= p.win then
    pcall(vim.api.nvim_win_set_cursor, p.win, { at + 1, 0 })
  end
end

---@param p Progress
function M.close(p)
  if not p then
    return
  end
  if vim.api.nvim_win_is_valid(p.win) then
    pcall(vim.api.nvim_win_close, p.win, true)
  end
end

---------------------------------------------------------------------------
-- stream-json decoding
---------------------------------------------------------------------------

--- Turn `claude --output-format stream-json` into human lines.
---
--- Chunks from the process do not respect line boundaries, so the caller keeps a
--- carry buffer and hands whole lines here.
---
--- Event shapes (verified against 2.1.220):
---   {"type":"assistant","message":{"content":[{"type":"tool_use","name":…,"input":…}
---                                             {"type":"text","text":…}
---                                             {"type":"thinking"}]}}
---   {"type":"result","result":"…"}
---   {"type":"system"|"user", …}   -- token accounting and tool results, not shown
---@return string|nil text, string|nil highlight
function M.describe(line)
  local ok, event = pcall(vim.json.decode, line)
  if not ok or type(event) ~= 'table' then
    return nil
  end

  if event.type == 'result' then
    return nil -- the caller reports completion itself
  end
  if event.type ~= 'assistant' then
    return nil
  end

  local content = event.message and event.message.content
  if type(content) ~= 'table' then
    return nil
  end

  for _, block in ipairs(content) do
    if block.type == 'tool_use' then
      local input = block.input or {}
      local target = input.file_path or input.pattern or input.command or ''
      target = vim.fs.basename(tostring(target))
      if #target > 30 then
        target = target:sub(1, 29) .. '…'
      end
      local verbs = { Read = '  read   ', Edit = '  edit   ', Write = '  write  ', Bash = '  run    ', Grep = '  search ' }
      return (verbs[block.name] or ('  ' .. tostring(block.name) .. ' ')) .. target, block.name == 'Edit' and 'DiffAdd' or 'Comment'
    elseif block.type == 'thinking' then
      return '  thinking…', 'Comment'
    elseif block.type == 'text' and block.text and block.text ~= '' then
      -- Only a hint that it replied. The full text is markdown and goes to its
      -- own buffer -- collapsing whitespace to fit this 46-column pane is what
      -- turned formatted answers into a single unreadable line.
      local first = block.text:match '^%s*([^\n]+)' or 'replied'
      if vim.fn.strdisplaywidth(first) > 38 then
        first = vim.fn.strcharpart(first, 0, 37) .. '…'
      end
      return '  ' .. first, 'Comment'
    end
  end
  return nil
end

return M
