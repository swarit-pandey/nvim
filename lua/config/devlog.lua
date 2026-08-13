-- A single append-only log of everything worth knowing while iterating on this
-- config: notifications, Neovim's own error messages, LSP attach/detach,
-- diagnostic counts, and every background agent run with its exit code and
-- output.
--
-- The point is that a second pair of eyes can read one file instead of asking
-- for screenshots. `:DevLogPath` prints where it lives.
--
-- Turn it off with `vim.g.devlog_enabled = false` in init.lua, or delete the
-- `require 'config.devlog'` line -- nothing else depends on it.

local M = {}

M.path = vim.fn.stdpath 'state' .. '/agent-debug.log'

local MAX_BYTES = 1024 * 1024 -- rotate past 1MB so it can't grow without bound
local enabled = true

local function timestamp()
  return os.date '%H:%M:%S'
end

local function rotate_if_needed()
  local stat = vim.uv.fs_stat(M.path)
  if stat and stat.size > MAX_BYTES then
    os.rename(M.path, M.path .. '.old')
  end
end

--- Append one entry. Multi-line values are indented so the log stays scannable.
function M.write(tag, message)
  if not enabled then
    return
  end
  rotate_if_needed()
  local ok, file = pcall(io.open, M.path, 'a')
  if not ok or not file then
    return
  end
  message = type(message) == 'string' and message or vim.inspect(message)
  local lines = vim.split(message, '\n', { plain = true })
  file:write(('%s [%-9s] %s\n'):format(timestamp(), tag, lines[1] or ''))
  for i = 2, #lines do
    file:write('                      | ' .. lines[i] .. '\n')
  end
  file:close()
end

---------------------------------------------------------------------------
-- Sources
---------------------------------------------------------------------------

local LEVEL = { [0] = 'TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR' }

--- Tee vim.notify. Idempotent: refuses to wrap a wrapper it already installed.
local function hook_notify()
  local original = vim.notify
  if original == M._wrapped_notify then
    return
  end
  local function wrapper(message, level, opts)
    M.write(LEVEL[level or 2] or 'INFO', tostring(message))
    return original(message, level, opts)
  end
  M._wrapped_notify = wrapper
  vim.notify = wrapper
end

--- Neovim prints its own errors (E5108, stack traces, LSP failures) into the
--- message history rather than through vim.notify, so poll and log what's new.
local seen = ''
local function poll_messages()
  -- Re-assert the notify tee. Any plugin can replace vim.notify at any point
  -- (snacks does, on load), which silently drops the hook; checking here means
  -- it heals itself rather than depending on load order. hook_notify() refuses
  -- to wrap its own wrapper, so this cannot nest.
  hook_notify()

  local ok, out = pcall(vim.fn.execute, 'messages')
  if not ok or out == seen then
    return
  end

  local fresh
  -- First poll: `seen` is empty, so the whole history is new. Treating that as a
  -- failed prefix match would throw away everything Neovim printed at startup,
  -- including early errors.
  if seen == '' or out:sub(1, #seen) == seen then
    fresh = out:sub(#seen + 1)
  else
    -- History wrapped (maxmsghist) or was cleared; re-syncing would duplicate
    -- everything, so note it and carry on.
    fresh = ''
    M.write('MSG', '(message history rotated)')
  end
  seen = out

  for line in fresh:gmatch '[^\n]+' do
    if line:match '%S' then
      M.write('MSG', line)
    end
  end
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

function M.setup()
  if vim.g.devlog_enabled == false then
    enabled = false
    return
  end

  M.write('SESSION', ('=== nvim started  cwd=%s  pid=%d ==='):format(vim.fn.getcwd(), vim.fn.getpid()))

  local group = vim.api.nvim_create_augroup('devlog', { clear = true })

  -- snacks replaces vim.notify during plugin load, so wrap after that settles.
  vim.api.nvim_create_autocmd('User', {
    pattern = 'VeryLazy',
    group = group,
    callback = hook_notify,
  })
  hook_notify()

  vim.api.nvim_create_autocmd('LspAttach', {
    group = group,
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      M.write('LSP', ('attach %s -> %s'):format(client and client.name or '?', vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ev.buf), ':~:.')))
    end,
  })

  -- Diagnostics, so the exact severities and sources are visible -- this is what
  -- decides whether <leader>ax finds anything.
  vim.api.nvim_create_autocmd('DiagnosticChanged', {
    group = group,
    callback = function(ev)
      local name = vim.api.nvim_buf_get_name(ev.buf)
      if name == '' then
        return
      end
      local names = { 'ERROR', 'WARN', 'INFO', 'HINT' }
      local parts = {}
      for _, d in ipairs(vim.diagnostic.get(ev.buf)) do
        table.insert(parts, ('L%d %s [%s] %s'):format(d.lnum + 1, names[d.severity], tostring(d.source), (d.message:gsub('\n', ' '))))
      end
      M.write('DIAG', ('%s -> %d'):format(vim.fn.fnamemodify(name, ':~:.'), #parts) .. (#parts > 0 and ('\n' .. table.concat(parts, '\n')) or ''))
    end,
  })

  local timer = vim.uv.new_timer()
  timer:start(1500, 1500, vim.schedule_wrap(poll_messages))

  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      poll_messages()
      M.write('SESSION', '=== nvim exiting ===')
    end,
  })

  vim.api.nvim_create_user_command('DevLog', function()
    vim.cmd('tabedit ' .. vim.fn.fnameescape(M.path))
    vim.cmd 'normal! G'
  end, { desc = 'Open the debug log' })

  vim.api.nvim_create_user_command('DevLogPath', function()
    vim.notify(M.path)
  end, { desc = 'Print the debug log path' })

  vim.api.nvim_create_user_command('DevLogClear', function()
    os.remove(M.path)
    seen = ''
    M.write('SESSION', '=== log cleared ===')
    vim.notify 'Debug log cleared'
  end, { desc = 'Clear the debug log' })

  -- Annotate the log before trying something, so the entries that follow have
  -- context: :DevLogMark about to press <leader>ax
  vim.api.nvim_create_user_command('DevLogMark', function(opts)
    M.write('MARK', opts.args ~= '' and opts.args or '---')
  end, { nargs = '*', desc = 'Write a marker into the debug log' })
end

return M
