return {
  {
    'nvim-neo-tree/neo-tree.nvim',
    branch = 'v3.x',
    cmd = 'Neotree',
    dependencies = {
      'nvim-lua/plenary.nvim',
      'MunifTanjim/nui.nvim',
    },
    keys = {
      { '<leader>e', '<cmd>Neotree toggle left<CR>', desc = 'Explorer (toggle)' },
      { '<leader>E', '<cmd>Neotree reveal left<CR>', desc = 'Explorer (reveal current file)' },
      { '<leader>ge', '<cmd>Neotree float git_status<CR>', desc = 'Git status tree' },
      { '<leader>be', '<cmd>Neotree toggle show buffers right<CR>', desc = 'Buffer tree' },
    },
    opts = {
      close_if_last_window = true, -- don't leave a lone sidebar behind
      popup_border_style = 'rounded',
      enable_git_status = true,
      enable_diagnostics = true,
      window = {
        position = 'left',
        width = 32,
        mappings = {
          ['<space>'] = 'none', -- free the leader key inside the tree
          ['l'] = 'open',
          ['h'] = 'close_node',
          ['<CR>'] = 'open',
          ['<Esc>'] = 'cancel',
          ['P'] = { 'toggle_preview', config = { use_float = true } },

          -- Neo-tree has no built-in "copy the path" command -- its
          -- `copy_to_clipboard` is an internal clipboard for cut/copy/paste of
          -- files, not the system one -- so these are plain functions.
          -- `y` stays bound to neo-tree's own file clipboard.
          ['Y'] = {
            function(state)
              local node = state.tree:get_node()
              if not node then
                return
              end
              local path = node:get_id()
              vim.fn.setreg('+', path)
              vim.notify('Copied: ' .. path)
            end,
            desc = 'Copy absolute path',
          },
          ['gy'] = {
            function(state)
              local node = state.tree:get_node()
              if not node then
                return
              end
              -- Relative is what you want for @-mentions and commit messages.
              local path = vim.fs.relpath(vim.uv.cwd(), node:get_id()) or node:get_id()
              vim.fn.setreg('+', path)
              vim.notify('Copied: ' .. path)
            end,
            desc = 'Copy relative path',
          },
        },
      },
      filesystem = {
        bind_to_cwd = false,
        follow_current_file = { enabled = true }, -- keep the tree in sync with the open buffer
        use_libuv_file_watcher = true, -- pick up changes made outside Neovim
        filtered_items = {
          visible = false,
          hide_dotfiles = false, -- dotfiles matter in a config repo
          hide_gitignored = true,
          hide_by_name = { '.git', 'node_modules', '.DS_Store' },
        },
      },
      default_component_configs = {
        indent = { with_expanders = true, expander_collapsed = '', expander_expanded = '' },
        git_status = {
          symbols = {
            added = '+',
            modified = '~',
            deleted = '-',
            renamed = '→',
            untracked = '?',
            ignored = '◌',
            unstaged = '󰄱',
            staged = '',
            conflict = '',
          },
        },
      },
    },
  },
}
