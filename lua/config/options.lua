local opt = vim.opt

-- [[ Appearance ]]
opt.number = true
opt.relativenumber = true
opt.signcolumn = 'yes' -- reserve the gutter so text doesn't jump when diagnostics appear
opt.cursorline = true
opt.colorcolumn = '100'
opt.wrap = false
opt.scrolloff = 10
opt.sidescrolloff = 8
opt.showmode = false -- lualine already shows it
opt.laststatus = 3 -- one statusline for all windows, not one per split
-- The agent view lives in its own tabpage; a tabline showing a terminal's URL
-- next to a filename is noise, and <leader>A already says which view you're in.
opt.showtabline = 0
opt.cmdheight = 1
opt.pumheight = 12
opt.termguicolors = true
opt.winborder = 'rounded' -- global float border (Neovim 0.11+)

-- Hide the vertical bars between splits; the theme dims inactive windows instead.
-- `diff` fills the gaps opposite a deleted block, and `fold` pads a closed fold:
-- both default to dashes and dots respectively, which read as noise inside a
-- review. A diagonal for one and nothing for the other keeps the diff legible.
opt.fillchars = {
  eob = ' ',
  horiz = '─',
  horizup = '─',
  horizdown = '─',
  vert = '│',
  vertleft = '│',
  vertright = '│',
  verthoriz = '│',
  diff = '╱',
  fold = ' ',
}

-- Diff engine. `linematch` is what pairs up changed lines so the highlight lands
-- on the words that actually differ rather than the whole block; the histogram
-- algorithm plus the indent heuristic keep hunks aligned to sensible boundaries.
-- `context` is deliberately generous — a review needs surrounding code to judge.
opt.diffopt = {
  'internal',
  'filler',
  'closeoff',
  'algorithm:histogram',
  'indent-heuristic',
  'linematch:60',
  'context:8',
}
opt.list = false
opt.listchars = { tab = '» ', trail = '·', nbsp = '␣' }

-- [[ Indentation ]]
-- Global default; per-language overrides live in config/autocmds.lua and
-- .editorconfig files are respected automatically (Neovim has builtin support).
opt.tabstop = 4
opt.shiftwidth = 4
opt.softtabstop = 4
opt.expandtab = true
opt.breakindent = true
-- `smartindent` is deliberately off. Neovim loads a per-language indent file for
-- every filetype here, and smartindent fights it (most visibly by yanking `#`
-- comments to column 0). autoindent plus the filetype indent is the correct pair.
opt.autoindent = true

-- [[ Search ]]
opt.ignorecase = true
opt.smartcase = true -- ...unless the query contains a capital
opt.hlsearch = true
opt.incsearch = true
opt.inccommand = 'split' -- live preview of :s///

-- [[ Splits ]]
opt.splitright = true
opt.splitbelow = true

-- [[ Files & undo ]]
opt.undofile = true
opt.swapfile = false
opt.backup = false
opt.confirm = true -- prompt instead of erroring on :q with unsaved changes

-- [[ Responsiveness ]]
opt.updatetime = 250 -- also drives CursorHold / gitsigns blame
opt.timeoutlen = 300 -- how long which-key waits before popping up
opt.mouse = 'a'

-- [[ Clipboard ]]
-- Scheduled so it doesn't block startup while Neovim probes clipboard providers.
-- With `unnamedplus`, every y/d/p uses the macOS system clipboard via pbcopy/pbpaste.
vim.schedule(function()
  vim.opt.clipboard = 'unnamedplus'
end)

-- Over SSH there is no pbcopy, so fall back to OSC 52 (the terminal itself carries
-- the copy). Ghostty supports this, so yanking on a remote box still hits the local
-- clipboard.
if vim.env.SSH_TTY or vim.env.SSH_CONNECTION then
  vim.g.clipboard = {
    name = 'OSC 52',
    copy = { ['+'] = require('vim.ui.clipboard.osc52').copy '+', ['*'] = require('vim.ui.clipboard.osc52').copy '*' },
    paste = { ['+'] = require('vim.ui.clipboard.osc52').paste '+', ['*'] = require('vim.ui.clipboard.osc52').paste '*' },
  }
end

-- [[ Diagnostics ]]
vim.diagnostic.config {
  severity_sort = true,
  float = { source = 'if_many' },
  underline = { severity = vim.diagnostic.severity.ERROR },
  signs = vim.g.have_nerd_font and {
    text = {
      [vim.diagnostic.severity.ERROR] = '󰅚 ',
      [vim.diagnostic.severity.WARN] = '󰀪 ',
      [vim.diagnostic.severity.INFO] = '󰋽 ',
      [vim.diagnostic.severity.HINT] = '󰌶 ',
    },
  } or true,
  virtual_text = {
    spacing = 2,
    source = 'if_many',
    prefix = '●',
  },
}
