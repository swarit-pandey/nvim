vim.g.barbar_auto_setup = false

require'barbar'.setup {
    auto_hide = 1,
    clickable = true,
    ['neo-tree'] = { event = 'BufWipeout' },
    undotree = { text = 'undotree' }
}
