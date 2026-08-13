-- Two views, Cursor-style: a code view and a full-window agent view.
--
-- The agent view is its own tabpage holding the Claude terminal as the only
-- window. Tabpages are the right primitive here because each one keeps an
-- independent window layout — flipping to the agent and back leaves your splits,
-- and the agent's scrollback, exactly as they were.
--
-- Window placement is managed here rather than by claudecode.nvim, which is safe
-- because its native provider re-discovers its terminal by scanning windows for
-- the buffer, and treats a hidden buffer as still valid.
--
-- ---------------------------------------------------------------------------
-- SWAPPING IN ANOTHER AGENT (opencode, aider, crush, ...)
-- ---------------------------------------------------------------------------
-- Almost none of this file is Claude-specific. The tabpage machinery, the
-- toggle, <C-q>, and the readiness polling all work against any CLI agent that
-- runs in a terminal buffer. There are exactly four touchpoints, each marked
-- with a `SWAP POINT` comment below:
--
--   1. claude_buf()            -- how to find the agent's terminal buffer
--   2. fill_tab_with_claude()  -- the command that spawns it
--   3. readiness()             -- how to tell it's ready for input
--   4. M.send_selection()      -- the "send visual selection" command
--
-- A fifth lives in lua/agent/lint.lua: the local `send()` function.
--
-- The cheap way to support two agents is to lift those five into a table of
-- backends, e.g.
--
--   local backends = {
--     claude   = { spawn = 'ClaudeCode', find_buf = ..., send = ..., ready = ... },
--     opencode = { spawn = 'Opencode',   find_buf = ..., send = ..., ready = ... },
--   }
--
-- and pick one with a module-level `M.backend`. That is roughly 30 lines and is
-- deliberately not done yet -- there is one agent today, and an abstraction with
-- a single implementation is just indirection.
--
-- Note that the IDE-level features (selection context, @-mentions, accept/reject
-- diffs) are NOT portable: each agent CLI speaks its own protocol, so those come
-- from that agent's own Neovim plugin rather than from this file.

local M = {}

local state = {
  agent_tab = nil, -- tabpage holding the agent
  code_tab = nil, -- where to return to
}

local function tab_valid(tab)
  return tab ~= nil and vim.api.nvim_tabpage_is_valid(tab)
end

--- The live Claude terminal buffer, or nil if no session has been started.
--- SWAP POINT 1/4: how to locate the agent's terminal buffer.
local function claude_buf()
  local ok, terminal = pcall(require, 'claudecode.terminal')
  if ok and type(terminal.get_active_terminal_bufnr) == 'function' then
    local got, bufnr = pcall(terminal.get_active_terminal_bufnr)
    if got and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      return bufnr
    end
  end

  -- Fallback: find the terminal buffer running claude ourselves. Keeps the view
  -- working if the plugin renames that accessor again.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == 'terminal' then
      if vim.api.nvim_buf_get_name(bufnr):match 'claude' then
        return bufnr
      end
    end
  end
  return nil
end

--- Find the window in the current tab showing `bufnr`.
local function window_showing(bufnr)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
end

function M.in_agent()
  return tab_valid(state.agent_tab) and vim.api.nvim_get_current_tabpage() == state.agent_tab
end

--- Make the Claude terminal the only window in the current (agent) tab.
local function fill_tab_with_claude()
  local bufnr = claude_buf()

  if bufnr then
    -- Session already running: just show it here. Nothing is respawned, so
    -- scrollback and in-flight work survive the view switch.
    vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), bufnr)
    vim.cmd 'only'
    vim.cmd 'startinsert'
    return
  end

  -- No session yet. Let the plugin spawn one, then collapse the tab down to it.
  -- SWAP POINT 2/4: the command that starts the agent.
  -- The first invocation also has to lazy-load claudecode.nvim and start its
  -- websocket server, so poll rather than guessing a single delay.
  vim.cmd 'ClaudeCode'

  local attempts = 0
  local function collapse()
    attempts = attempts + 1
    if not M.in_agent() then
      return -- user navigated away while the terminal was starting
    end
    local buf = claude_buf()
    local win = buf and window_showing(buf)
    if win then
      vim.api.nvim_set_current_win(win)
      vim.cmd 'only'
      vim.cmd 'startinsert'
    elseif attempts < 20 then
      vim.defer_fn(collapse, 100)
    end
  end
  vim.defer_fn(collapse, 100)
end

--- Switch to the agent view, creating it if needed.
function M.agent()
  if M.in_agent() then
    return
  end

  state.code_tab = vim.api.nvim_get_current_tabpage()

  if tab_valid(state.agent_tab) then
    vim.api.nvim_set_current_tabpage(state.agent_tab)
    -- The tab may have been left empty if the terminal was closed from inside it.
    local buf = claude_buf()
    if not buf or not window_showing(buf) then
      fill_tab_with_claude()
    else
      vim.api.nvim_set_current_win(window_showing(buf))
      vim.cmd 'startinsert'
    end
  else
    vim.cmd 'tabnew'
    state.agent_tab = vim.api.nvim_get_current_tabpage()
    -- `tabnew` leaves an empty unnamed buffer behind once the terminal takes over
    -- the window. It lingers in the buffer list, and `:wqa` fails on it with
    -- "E676: No matching autocommands for buftype= buffer" because there is
    -- nothing to write it to.
    local placeholder = vim.api.nvim_get_current_buf()
    fill_tab_with_claude()
    vim.defer_fn(function()
      if
        vim.api.nvim_buf_is_valid(placeholder)
        and vim.fn.bufname(placeholder) == ''
        and vim.fn.bufwinid(placeholder) == -1
        and vim.api.nvim_buf_line_count(placeholder) <= 1
      then
        pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
      end
    end, 400)
  end
end

--- Switch back to the code view.
function M.code()
  if not M.in_agent() then
    return
  end

  vim.cmd 'stopinsert'

  if tab_valid(state.code_tab) and state.code_tab ~= state.agent_tab then
    vim.api.nvim_set_current_tabpage(state.code_tab)
    return
  end

  -- Lost track of where we came from: fall back to any other tab, or make one
  -- rather than stranding the user in the agent view.
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if tab ~= state.agent_tab then
      state.code_tab = tab
      vim.api.nvim_set_current_tabpage(tab)
      return
    end
  end

  vim.cmd 'tabnew'
  state.code_tab = vim.api.nvim_get_current_tabpage()
end

function M.toggle()
  if M.in_agent() then
    M.code()
  else
    M.agent()
  end
end

M.claude_buf = claude_buf

--- Is Claude's TUI actually accepting typed input yet?
---
--- A cold start takes seconds (plugin load, websocket server, CLI boot), and in
--- an unfamiliar directory the CLI opens on a "do you trust this folder?" prompt.
--- Typing into either state loses the message, so callers have to wait for the
--- real input box rather than for the buffer merely existing.
--- SWAP POINT 3/4: how to tell the agent is accepting input. Every CLI draws a
--- different prompt, so this is the piece most likely to need rewriting.
---@return 'ready'|'trust'|'starting'
local function readiness(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, -80, -1, false)
  local text = table.concat(lines, '\n')

  if text:find('trust this folder', 1, true) or text:find('Is this a project you created', 1, true) then
    return 'trust'
  end
  -- '❯' is the input prompt marker, drawn once the CLI is ready for a message.
  if text:find('❯', 1, true) then
    return 'ready'
  end
  return 'starting'
end

--- Open the agent view and invoke `callback` once Claude is genuinely ready for
--- input.
function M.ensure_ready(callback, _attempt)
  local attempt = _attempt or 0
  if attempt == 0 then
    M.agent()
  end

  local bufnr = claude_buf()
  if bufnr then
    local state = readiness(bufnr)
    if state == 'ready' then
      callback()
      return
    end
    if state == 'trust' then
      vim.notify('Claude is asking whether to trust this folder. Answer that first, then try again.', vim.log.levels.WARN)
      return
    end
  end

  if attempt > 150 then -- ~20s
    vim.notify('Claude did not become ready in time', vim.log.levels.ERROR)
    return
  end

  vim.defer_fn(function()
    M.ensure_ready(callback, attempt + 1)
  end, 130)
end

--- Send the visual selection to Claude, then jump to the agent view — the
--- "explain/change this" path, in one key.
--- SWAP POINT 4/4: the agent's "send selection" command.
function M.send_selection()
  vim.cmd 'ClaudeCodeSend'
  vim.defer_fn(function()
    M.agent()
  end, 80)
end

function M.setup()
  local map = vim.keymap.set

  -- Primary: one key, no modifier chord, same key both directions. Bound in
  -- terminal mode too so you can leave the agent without first dropping out of
  -- terminal mode.
  --
  -- This shadows Neovim's <C-q> alias for blockwise visual, which is no loss —
  -- <C-v> is the real binding for that and still works.
  --
  -- <Esc> is deliberately left alone: Claude uses it to interrupt a running turn.
  map('n', '<C-q>', M.toggle, { desc = 'Toggle agent view' })
  map('t', '<C-q>', M.code, { desc = 'Back to code view' })

  -- Lowercase leader alternative, for when your hand is already on <leader>.
  -- NOT <leader>av: that belongs to the review inbox (lua/agent/inbox.lua), which
  -- is set up after this module and was silently winning the collision.
  map('n', '<leader>ao', M.agent, { desc = 'Open agent view' })

  -- Kept for muscle memory, but <C-q> does the same thing.
  map('n', '<leader>A', M.toggle, { desc = 'Toggle agent view' })

  map('v', '<leader>aS', M.send_selection, { desc = 'Send selection and open agent view' })

  vim.api.nvim_create_user_command('AgentView', M.agent, { desc = 'Open the full-window agent view' })
  vim.api.nvim_create_user_command('CodeView', M.code, { desc = 'Return to the code view' })

  -- If the agent tab is closed by hand, forget it so the next toggle rebuilds it.
  vim.api.nvim_create_autocmd('TabClosed', {
    group = vim.api.nvim_create_augroup('agent_view', { clear = true }),
    callback = function()
      if not tab_valid(state.agent_tab) then
        state.agent_tab = nil
      end
      if not tab_valid(state.code_tab) then
        state.code_tab = nil
      end
    end,
  })
end

return M
