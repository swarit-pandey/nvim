local map = vim.keymap.set

-- [[ Basics ]]
map('n', '<Esc>', '<cmd>nohlsearch<CR>', { desc = 'Clear search highlight' })
map('n', '<leader>w', '<cmd>write<CR>', { desc = 'Write file' })
map('n', '<leader>q', '<cmd>quit<CR>', { desc = 'Quit window' })
map('i', 'jk', '<Esc>', { desc = 'Exit insert mode' })

-- [[ Clipboard ]]
-- `clipboard=unnamedplus` already routes everything to the system clipboard, but
-- these stay explicit for when that gets toggled off.
map({ 'n', 'v' }, '<leader>y', '"+y', { desc = 'Yank to system clipboard' })
map('n', '<leader>Y', '"+Y', { desc = 'Yank line to system clipboard' })
map({ 'n', 'v' }, '<leader>p', '"+p', { desc = 'Paste from system clipboard' })
-- Paste over a selection without clobbering the register with what you replaced.
map('x', '<leader>P', [["_dP]], { desc = 'Paste over selection (keep register)' })
-- Delete without touching the yank register.
map({ 'n', 'v' }, '<leader>d', [["_d]], { desc = 'Delete (no register)' })

-- [[ Movement ]]
-- Keep the cursor centred while scrolling and jumping between matches.
map('n', '<C-d>', '<C-d>zz', { desc = 'Half page down (centred)' })
map('n', '<C-u>', '<C-u>zz', { desc = 'Half page up (centred)' })
map('n', 'n', 'nzzzv', { desc = 'Next match (centred)' })
map('n', 'N', 'Nzzzv', { desc = 'Prev match (centred)' })

-- Move the selected lines up/down, re-indenting as they go.
map('v', 'J', ":m '>+1<CR>gv=gv", { desc = 'Move selection down' })
map('v', 'K', ":m '<-2<CR>gv=gv", { desc = 'Move selection up' })

-- Stay in visual mode when shifting indentation.
map('v', '<', '<gv', { desc = 'Outdent' })
map('v', '>', '>gv', { desc = 'Indent' })

-- [[ Windows ]]
map('n', '<C-h>', '<C-w><C-h>', { desc = 'Focus window left' })
map('n', '<C-l>', '<C-w><C-l>', { desc = 'Focus window right' })
map('n', '<C-j>', '<C-w><C-j>', { desc = 'Focus window down' })
map('n', '<C-k>', '<C-w><C-k>', { desc = 'Focus window up' })
map('n', '<C-Up>', '<cmd>resize +2<CR>', { desc = 'Grow window' })
map('n', '<C-Down>', '<cmd>resize -2<CR>', { desc = 'Shrink window' })
map('n', '<C-Left>', '<cmd>vertical resize -2<CR>', { desc = 'Narrow window' })
map('n', '<C-Right>', '<cmd>vertical resize +2<CR>', { desc = 'Widen window' })

-- [[ Buffers ]]
map('n', '<S-l>', '<cmd>bnext<CR>', { desc = 'Next buffer' })
map('n', '<S-h>', '<cmd>bprevious<CR>', { desc = 'Previous buffer' })
map('n', '<leader>bd', '<cmd>bdelete<CR>', { desc = 'Delete buffer' })
map('n', '<leader>bo', '<cmd>%bdelete|edit#|bdelete#<CR>', { desc = 'Delete other buffers' })

-- [[ Diagnostics ]]
map('n', '<leader>xd', vim.diagnostic.open_float, { desc = 'Line diagnostics' })
map('n', '<leader>xl', vim.diagnostic.setloclist, { desc = 'Diagnostics to loclist' })

-- [[ Terminal ]]
map('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })

-- [[ Toggles ]] (<leader>u = UI)
local function toggle(opt_name, label)
  return function()
    vim.opt_local[opt_name] = not vim.opt_local[opt_name]:get()
    vim.notify(label .. ': ' .. tostring(vim.opt_local[opt_name]:get()))
  end
end

map('n', '<leader>uw', toggle('wrap', 'Wrap'), { desc = 'Toggle wrap' })
map('n', '<leader>ul', toggle('list', 'Listchars'), { desc = 'Toggle whitespace chars' })
map('n', '<leader>un', toggle('relativenumber', 'Relative number'), { desc = 'Toggle relative numbers' })
map('n', '<leader>us', toggle('spell', 'Spell'), { desc = 'Toggle spellcheck' })

-- Turning the mouse off hands click-drag selection back to Ghostty, so you can
-- select-and-copy with the terminal's own selection instead of Neovim's.
-- (Holding Shift while dragging does the same thing without toggling.)
map('n', '<leader>um', function()
  local on = vim.o.mouse ~= ''
  vim.o.mouse = on and '' or 'a'
  vim.notify('Mouse: ' .. (on and 'off (terminal selection)' or 'on'))
end, { desc = 'Toggle mouse (terminal selection)' })

map('n', '<leader>ud', function()
  local enabled = vim.diagnostic.is_enabled()
  vim.diagnostic.enable(not enabled)
  vim.notify('Diagnostics: ' .. tostring(not enabled))
end, { desc = 'Toggle diagnostics' })
