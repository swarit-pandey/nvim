return {
  -- Git signs in the gutter, staging and blame without leaving the buffer.
  {
    'lewis6991/gitsigns.nvim',
    event = { 'BufReadPre', 'BufNewFile' },
    opts = {
      signs = {
        add = { text = '┃' },
        change = { text = '┃' },
        delete = { text = '' },
        topdelete = { text = '' },
        changedelete = { text = '~' },
        untracked = { text = '┆' },
      },
      on_attach = function(bufnr)
        local gs = require 'gitsigns'
        local function map(mode, keys, fn, desc)
          vim.keymap.set(mode, keys, fn, { buffer = bufnr, desc = 'Git: ' .. desc })
        end

        map('n', ']c', function()
          if vim.wo.diff then
            vim.cmd.normal { ']c', bang = true }
          else
            gs.nav_hunk 'next'
          end
        end, 'Next hunk')

        map('n', '[c', function()
          if vim.wo.diff then
            vim.cmd.normal { '[c', bang = true }
          else
            gs.nav_hunk 'prev'
          end
        end, 'Previous hunk')

        map({ 'n', 'v' }, '<leader>gs', gs.stage_hunk, 'Stage hunk')
        map({ 'n', 'v' }, '<leader>gr', gs.reset_hunk, 'Reset hunk')
        map('n', '<leader>gS', gs.stage_buffer, 'Stage buffer')
        map('n', '<leader>gR', gs.reset_buffer, 'Reset buffer')
        map('n', '<leader>gp', gs.preview_hunk, 'Preview hunk')
        map('n', '<leader>gb', gs.blame_line, 'Blame line')
        map('n', '<leader>gB', gs.blame, 'Blame file')
        map('n', '<leader>gd', gs.diffthis, 'Diff against index')
        map('n', '<leader>gD', function()
          gs.diffthis '@'
        end, 'Diff against last commit')
        map('n', '<leader>ub', gs.toggle_current_line_blame, 'Toggle inline blame')
      end,
    },
  },

  -- Review everything that changed, across files, in one place.
  --
  -- This is the "go through what the agent did" step. It diffs the working tree,
  -- so it catches edits however they were written -- through Claude's in-editor
  -- proposal, through its own file tools, or by you. Rejecting a hunk is
  -- gitsigns' `<leader>gr` (reset_hunk), which works in the diff panes.
  {
    'sindrets/diffview.nvim',
    cmd = { 'DiffviewOpen', 'DiffviewClose', 'DiffviewToggleFiles', 'DiffviewFileHistory', 'DiffviewRefresh' },
    opts = {
      enhanced_diff_hl = true, -- clearer intra-line highlighting
      file_panel = {
        listing_style = 'list',
        win_config = { width = 32 },
      },
      view = {
        default = { winbar_info = true }, -- show which revision each side is
        merge_tool = { layout = 'diff3_mixed' },
      },
      keymaps = {
        view = {
          { 'n', 'q', '<cmd>DiffviewClose<CR>', { desc = 'Close review' } },
          { 'n', '<Tab>', '<cmd>DiffviewToggleFiles<CR>', { desc = 'Toggle file panel' } },
        },
        file_panel = {
          { 'n', 'q', '<cmd>DiffviewClose<CR>', { desc = 'Close review' } },
          { 'n', '<Tab>', '<cmd>DiffviewToggleFiles<CR>', { desc = 'Toggle file panel' } },
        },
      },
    },
    keys = {
      {
        '<leader>gv',
        function()
          -- Toggle: reopening on top of an open view stacks tabs.
          local ok, lib = pcall(require, 'diffview.lib')
          if ok and lib.get_current_view() then
            vim.cmd 'DiffviewClose'
          else
            vim.cmd 'DiffviewOpen'
          end
        end,
        desc = 'Review all changes (diffview)',
      },
      { '<leader>gl', '<cmd>DiffviewFileHistory %<CR>', desc = 'History of this file' },
      { '<leader>gL', '<cmd>DiffviewFileHistory<CR>', desc = 'History of this branch' },
    },
  },

  -- Telescope covers most git browsing; these are the pickers worth a binding.
  {
    'nvim-telescope/telescope.nvim',
    optional = true,
    keys = {
      { '<leader>gc', '<cmd>Telescope git_commits<CR>', desc = 'Git commits' },
      { '<leader>gf', '<cmd>Telescope git_bcommits<CR>', desc = 'Git commits (this file)' },
      { '<leader>gg', '<cmd>Telescope git_status<CR>', desc = 'Git status' },
      { '<leader>gh', '<cmd>Telescope git_branches<CR>', desc = 'Git branches' },
    },
  },

  -- [[ mini.nvim odds and ends ]]

  -- Extra text objects: `va(`-style but for arguments, functions, and more.
  -- e.g. `dif` deletes inside a function, `caa` changes an argument.
  {
    'echasnovski/mini.ai',
    version = false,
    event = 'VeryLazy',
    opts = { n_lines = 500 },
  },

  -- Add/delete/replace surroundings: `saiw)` surrounds a word in parens,
  -- `sd'` deletes the surrounding quotes, `sr)'` replaces parens with quotes.
  {
    'echasnovski/mini.surround',
    version = false,
    event = 'VeryLazy',
    opts = {},
  },

  -- Auto-close brackets and quotes -- except braces, which are typed by hand.
  {
    'echasnovski/mini.pairs',
    version = false,
    event = 'InsertEnter',
    config = function()
      local pairs = require 'mini.pairs'
      pairs.setup()

      -- `{` opens a block you finish later, so auto-inserting `}` gets in the
      -- way; `(`, `[` and quotes close on the same line and are left alone.
      --
      -- Unmapped after setup rather than disabled in `opts`: setup() reads
      -- `pair_info.action` off every entry, so a `false` there errors out.
      -- Unmapping also deregisters the pair, so <BS> and <CR> stop treating
      -- `{}` specially too.
      pairs.unmap('i', '{', '{}')
      pairs.unmap('i', '}', '{}')
    end,
  },

  -- Highlights and lists TODO/FIXME/HACK/NOTE comments.
  {
    'folke/todo-comments.nvim',
    event = { 'BufReadPost', 'BufNewFile' },
    dependencies = { 'nvim-lua/plenary.nvim' },
    opts = { signs = false },
    keys = {
      { '<leader>st', '<cmd>TodoTelescope<CR>', desc = '[S]earch [T]odos' },
    },
  },
}
