-- Reload the local agent modules without restarting Neovim.
--
-- Lua caches modules in `package.loaded` for the life of the process, so editing
-- a file under lua/agent/ changes nothing in an already-running session. That is
-- not a theoretical problem: a fix landed on disk, three sessions kept running
-- the old code, and the feature looked broken for hours afterwards.
local M = {}

local prefixes = { 'agent%.', 'config%.devlog', 'ghostty%.', 'notes' }

local function owned(name)
  for _, p in ipairs(prefixes) do
    if name:match('^' .. p) then
      return true
    end
  end
  return false
end

M._watchers = {}

--- Drop the cached copies and re-run the setup functions.
---@param opts table|nil { quiet = true } to skip the notification
function M.reload(opts)
  opts = opts or {}
  local dropped = {}
  for name in pairs(package.loaded) do
    if owned(name) then
      package.loaded[name] = nil
      table.insert(dropped, name)
    end
  end
  table.sort(dropped)

  -- Re-register keymaps, commands and autocommands against the fresh modules.
  for _, mod in ipairs { 'agent.view', 'agent.lint', 'agent.diff', 'agent.inbox', 'notes' } do
    local ok, m = pcall(require, mod)
    if ok and type(m.setup) == 'function' then
      pcall(m.setup)
    end
  end

  if not opts.quiet then
    vim.notify(('Reloaded %d module%s: %s'):format(#dropped, #dropped == 1 and '' or 's', table.concat(dropped, ', ')))
  elseif #dropped > 0 then
    vim.notify(('config reloaded (%d modules)'):format(#dropped), vim.log.levels.INFO)
  end
end

--- Reload automatically when the files change on disk.
---
--- The manual command was not enough: a fix landed, the running session kept the
--- old module, and the same error reappeared as if nothing had been fixed --
--- twice. Editing this config from another window (or having an agent edit it)
--- has to take effect without remembering a command.
---
--- Watches directories rather than files, because a write that replaces the inode
--- (which most editors do) makes a file watch go deaf after the first change.
local function watch()
  local root = vim.fn.stdpath 'config' .. '/lua'
  local timer = vim.uv.new_timer()

  for _, sub in ipairs { '/agent', '/ghostty', '/notes' } do
    local dir = root .. sub
    if vim.uv.fs_stat(dir) then
      local handle = vim.uv.new_fs_event()
      handle:start(
        dir,
        {},
        vim.schedule_wrap(function(err, filename)
          if err or not filename or not filename:match '%.lua$' then
            return
          end
          -- Debounced: a single save can emit several events, and an agent
          -- rewriting three files should reload once.
          timer:stop()
          timer:start(
            250,
            0,
            vim.schedule_wrap(function()
              M.reload { quiet = true }
            end)
          )
        end)
      )
      table.insert(M._watchers, handle)
    end
  end
end

function M.setup()
  vim.api.nvim_create_user_command('AgentReload', function()
    M.reload()
  end, { desc = 'Reload lua/agent/* without restarting' })
  vim.keymap.set('n', '<leader>aR', function()
    M.reload()
  end, { desc = 'Reload agent modules' })
  watch()
end

return M
