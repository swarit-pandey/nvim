-- Bootstrap lazy.nvim, then load every spec under lua/plugins/.
local lazypath = vim.fn.stdpath 'data' .. '/lazy/lazy.nvim'

if not vim.uv.fs_stat(lazypath) then
  local out = vim.fn.system { 'git', 'clone', '--filter=blob:none', '--branch=stable', 'https://github.com/folke/lazy.nvim.git', lazypath }
  if vim.v.shell_error ~= 0 then
    error('Failed to clone lazy.nvim:\n' .. out)
  end
end

vim.opt.rtp:prepend(lazypath)

require('lazy').setup {
  spec = { { import = 'plugins' } },
  install = { colorscheme = { 'habamax' } },
  checker = { enabled = true, notify = false }, -- check for updates quietly
  change_detection = { notify = false },
  ui = { border = 'rounded' },
  performance = {
    rtp = {
      -- Builtin plugins we don't use; skipping them shaves startup time.
      disabled_plugins = { 'gzip', 'tarPlugin', 'tohtml', 'tutor', 'zipPlugin', 'netrwPlugin' },
    },
  },
}

vim.keymap.set('n', '<leader>L', '<cmd>Lazy<CR>', { desc = 'Lazy (plugin manager)' })
