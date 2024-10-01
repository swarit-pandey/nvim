local builtin = require('telescope.builtin')
vim.keymap.set('n', '<leader>l', builtin.find_files, {}) -- fuzzy find the files
vim.keymap.set('n', '<C-p>', builtin.git_files, {})      -- include git
vim.keymap.set('n', '<leader>b', builtin.buffers, {})
vim.keymap.set('n', '<leader>z', function()
    builtin.grep_string({ search = vim.fn.input("RIP > ") }); -- Grepit!
end)
