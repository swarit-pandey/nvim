local builtin = require('telescope.builtin')
vim.keymap.set('n', '<leader>find', builtin.find_files, {}) -- fuzzy find the files
vim.keymap.set('n', '<C-p>', builtin.git_files, {}) -- include git
vim.keymap.set('n', '<leader>buf', builtin.buffers, {})
vim.keymap.set('n', '<leader>rip', function()
	builtin.grep_string({ search = vim.fn.input("RIP > ") }); -- Grepit!
end)
