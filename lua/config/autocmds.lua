local function augroup(name)
  return vim.api.nvim_create_augroup('swarit_' .. name, { clear = true })
end

-- Briefly highlight whatever was just yanked, so you can see what landed in the register.
vim.api.nvim_create_autocmd('TextYankPost', {
  group = augroup 'highlight_yank',
  callback = function()
    vim.hl.on_yank { timeout = 150 }
  end,
})

-- Reopen a file at the line you left it on.
vim.api.nvim_create_autocmd('BufReadPost', {
  group = augroup 'last_location',
  callback = function(ev)
    local exclude = { 'gitcommit', 'gitrebase' }
    if vim.tbl_contains(exclude, vim.bo[ev.buf].filetype) then
      return
    end
    local mark = vim.api.nvim_buf_get_mark(ev.buf, '"')
    if mark[1] > 0 and mark[1] <= vim.api.nvim_buf_line_count(ev.buf) then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end,
})

-- Strip trailing whitespace on save. Formatters handle this for most languages,
-- but this covers files with no formatter configured.
vim.api.nvim_create_autocmd('BufWritePre', {
  group = augroup 'trim_whitespace',
  callback = function()
    if vim.bo.filetype == 'markdown' then
      return -- two trailing spaces is a hard line break in markdown
    end
    local view = vim.fn.winsaveview()
    vim.cmd [[keeppatterns %s/\s\+$//e]]
    vim.fn.winrestview(view)
  end,
})

-- Per-language indentation. Anything not listed uses the 4-space global default.
-- An .editorconfig in the repo overrides all of this.
local indents = {
  [2] = {
    'javascript',
    'javascriptreact',
    'typescript',
    'typescriptreact',
    'json',
    'jsonc',
    'yaml',
    'html',
    'css',
    'scss',
    'lua',
    'markdown',
    'sh',
    'bash',
    'terraform',
    'hcl',
  },
  [4] = { 'python', 'rust', 'java' },
}
for width, filetypes in pairs(indents) do
  vim.api.nvim_create_autocmd('FileType', {
    group = augroup('indent_' .. width),
    pattern = filetypes,
    callback = function()
      vim.bo.tabstop = width
      vim.bo.shiftwidth = width
      vim.bo.softtabstop = width
      vim.bo.expandtab = true
    end,
  })
end

-- Go uses real tabs, by decree of gofmt.
vim.api.nvim_create_autocmd('FileType', {
  group = augroup 'indent_go',
  pattern = { 'go', 'gomod', 'gowork' },
  callback = function()
    vim.bo.expandtab = false
    vim.bo.tabstop = 4
    vim.bo.shiftwidth = 4
  end,
})

-- `q` closes throwaway windows instead of trying to quit Neovim.
vim.api.nvim_create_autocmd('FileType', {
  group = augroup 'close_with_q',
  pattern = { 'help', 'qf', 'man', 'lspinfo', 'checkhealth', 'notify', 'query', 'startuptime' },
  callback = function(ev)
    vim.bo[ev.buf].buflisted = false
    vim.keymap.set('n', 'q', '<cmd>close<CR>', { buffer = ev.buf, silent = true })
  end,
})

-- Terminal buffers: no line numbers, straight into insert mode.
vim.api.nvim_create_autocmd('TermOpen', {
  group = augroup 'terminal',
  callback = function()
    vim.opt_local.number = false
    vim.opt_local.relativenumber = false
    vim.opt_local.signcolumn = 'no'
  end,
})

-- Prose wraps; code doesn't.
vim.api.nvim_create_autocmd('FileType', {
  group = augroup 'prose',
  pattern = { 'markdown', 'gitcommit', 'text' },
  callback = function()
    vim.opt_local.wrap = true
    vim.opt_local.linebreak = true
    vim.opt_local.spell = true
  end,
})

-- Let `:wqa` actually quit.
--
-- Neovim refuses to exit while a terminal job is alive ("E948: Job still
-- running"), and the agent view runs `claude` in a terminal buffer. Since that
-- session is a child of this Neovim and dies with it regardless, there is nothing
-- to preserve by blocking the quit -- so close those buffers first.
--
-- Also wipes empty unnamed buffers, which `:wa` cannot write and reports as
-- "E676: No matching autocommands for buftype= buffer".
vim.api.nvim_create_autocmd('ExitPre', {
  group = augroup 'clean_exit',
  callback = function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        local bt = vim.bo[buf].buftype
        local nameless = vim.api.nvim_buf_get_name(buf) == ''
        if bt == 'terminal' or (bt == '' and nameless and vim.api.nvim_buf_line_count(buf) <= 1) then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end
    end
  end,
})

-- Rebalance splits when the terminal window is resized.
vim.api.nvim_create_autocmd('VimResized', {
  group = augroup 'resize_splits',
  callback = function()
    local tab = vim.fn.tabpagenr()
    vim.cmd 'tabdo wincmd ='
    vim.cmd('tabnext ' .. tab)
  end,
})
