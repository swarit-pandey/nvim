-- All the kickstart <leader>s* bindings are preserved verbatim, plus a <leader>f*
-- set for the file/buffer pickers you reach for most.
return {
  {
    'nvim-telescope/telescope.nvim',
    event = 'VimEnter',
    dependencies = {
      'nvim-lua/plenary.nvim',
      {
        'nvim-telescope/telescope-fzf-native.nvim',
        build = 'make',
        cond = function()
          return vim.fn.executable 'make' == 1
        end,
      },
      'nvim-telescope/telescope-ui-select.nvim',
    },
    config = function()
      local telescope = require 'telescope'
      local actions = require 'telescope.actions'

      telescope.setup {
        defaults = {
          prompt_prefix = '  ',
          -- These two MUST have the same display width. Telescope swaps one for
          -- the other on the selected row, so a mismatch shifts that row sideways
          -- and throws off its column padding, which shows up as rows appearing to
          -- indent themselves as you move j/k.
          selection_caret = '❯ ',
          entry_prefix = '  ',
          path_display = { 'filename_first' }, -- name first, directory dimmed after
          sorting_strategy = 'ascending',
          layout_strategy = 'flex',
          layout_config = {
            prompt_position = 'top',
            horizontal = { preview_width = 0.55 },
            vertical = { preview_height = 0.5 },
            flex = { flip_columns = 140 },
          },
          mappings = {
            i = {
              ['<C-j>'] = actions.move_selection_next,
              ['<C-k>'] = actions.move_selection_previous,
              ['<C-q>'] = actions.smart_send_to_qflist + actions.open_qflist,
              ['<C-u>'] = false, -- let <C-u> clear the prompt instead of scrolling preview
              ['<Esc>'] = actions.close, -- close from insert mode, no double-escape
            },
          },
        },
        pickers = {
          find_files = { hidden = true, file_ignore_patterns = { '^%.git/' } },
          buffers = {
            sort_mru = true, -- most recently used first
            ignore_current_buffer = false, -- list everything, including this one
            mappings = { i = { ['<C-d>'] = actions.delete_buffer } },
          },
        },
        extensions = {
          ['ui-select'] = { require('telescope.themes').get_dropdown() },
        },
      }

      pcall(telescope.load_extension, 'fzf')
      pcall(telescope.load_extension, 'ui-select')

      local builtin = require 'telescope.builtin'
      local map = vim.keymap.set

      -- [[ Search — the kickstart bindings you already know ]]
      map('n', '<leader>sh', builtin.help_tags, { desc = '[S]earch [H]elp' })
      map('n', '<leader>sk', builtin.keymaps, { desc = '[S]earch [K]eymaps' })
      map('n', '<leader>sf', builtin.find_files, { desc = '[S]earch [F]iles' })
      map('n', '<leader>ss', builtin.builtin, { desc = '[S]earch [S]elect Telescope' })
      map('n', '<leader>sw', builtin.grep_string, { desc = '[S]earch current [W]ord' })
      map('n', '<leader>sg', builtin.live_grep, { desc = '[S]earch by [G]rep' })
      map('n', '<leader>sd', builtin.diagnostics, { desc = '[S]earch [D]iagnostics' })
      map('n', '<leader>sr', builtin.resume, { desc = '[S]earch [R]esume' })
      map('n', '<leader>s.', builtin.oldfiles, { desc = '[S]earch Recent Files' })
      map('n', '<leader><leader>', builtin.buffers, { desc = '[ ] Find existing buffers' })

      -- [[ Additions ]]
      map('n', '<leader>sc', builtin.commands, { desc = '[S]earch [C]ommands' })
      map('n', '<leader>sm', builtin.marks, { desc = '[S]earch [M]arks' })
      map('n', '<leader>sj', builtin.jumplist, { desc = '[S]earch [J]umplist' })
      map('n', '<leader>sq', builtin.quickfix, { desc = '[S]earch [Q]uickfix' })
      map('v', '<leader>sw', builtin.grep_string, { desc = '[S]earch selection' })

      -- Short aliases for the two you use constantly.
      map('n', '<leader>ff', builtin.find_files, { desc = '[F]ind [F]iles' })
      map('n', '<leader>fg', builtin.live_grep, { desc = '[F]ind by [G]rep' })
      map('n', '<leader>fb', builtin.buffers, { desc = '[F]ind [B]uffers' })
      -- Also under the Buffer group, so `<leader>b` shows a way to list them.
      map('n', '<leader>bb', builtin.buffers, { desc = 'List / switch buffers' })
      map('n', '<leader>fr', builtin.oldfiles, { desc = '[F]ind [R]ecent' })

      -- Fuzzy-find inside the current buffer, in a compact dropdown.
      map('n', '<leader>/', function()
        builtin.current_buffer_fuzzy_find(require('telescope.themes').get_dropdown {
          winblend = 10,
          previewer = false,
        })
      end, { desc = 'Fuzzy search in current buffer' })

      -- Grep only the files currently open.
      map('n', '<leader>s/', function()
        builtin.live_grep { grep_open_files = true, prompt_title = 'Live grep in open files' }
      end, { desc = '[S]earch [/] in open files' })

      -- Search this config from anywhere.
      map('n', '<leader>sn', function()
        builtin.find_files { cwd = vim.fn.stdpath 'config' }
      end, { desc = '[S]earch [N]eovim config' })
    end,
  },
}
