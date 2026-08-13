-- Entry point.
--
-- Layout:
--   lua/config/*   -- pure vim settings, no plugins
--   lua/plugins/*  -- one file per concern, each returns a lazy.nvim spec
--   lua/ghostty/*  -- reads the live Ghostty theme and mirrors it into Neovim

-- Leader must be set before lazy.nvim loads, or plugin keymaps bind to the wrong key.
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '
vim.g.have_nerd_font = true

-- Debug log: tees notifications, errors, diagnostics and agent runs to
-- ~/.local/state/nvim/agent-debug.log. Set vim.g.devlog_enabled = false above to
-- silence it, or remove this line entirely.
require('config.devlog').setup()

require 'config.options'
require 'config.keymaps'
require 'config.autocmds'
require 'config.lazy'

-- Bound here rather than from the plugin's config, so the agent view keys exist
-- from startup. Pressing one lazy-loads claudecode.nvim on demand.
require('agent.view').setup()
require('agent.lint').setup()
require('agent.diff').setup()
require('agent.inbox').setup()
require('config.reload').setup()

-- Reading the specs and ledgers agents write to ~/notes/, in a float over
-- whatever you are looking at. Point it elsewhere with setup { dirs = { ... } }.
require('notes').setup()
