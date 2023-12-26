local builtin = require('telescope.builtin')
vim.keymap.set('n', '<leader>pf', builtin.find_files, {}) -- fuzzy find the files
vim.keymap.set('n', '<C-p>', builtin.git_files, {}) -- include git
vim.keymap.set('n', '<leader>ps', function() 
	builtin.grep_string({ search = vim.fn.input("RIP > ") }); -- Grepit!
end)
