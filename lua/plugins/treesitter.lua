-- nvim-treesitter's `master` branch, not `main`.
--
-- `main` requires Neovim 0.12 (nightly); this is 0.11. On 0.11 its install()
-- dies on `vim.list.unique` (added in 0.12), so no parsers and -- more to the
-- point -- no *queries* are ever installed. Highlighting then silently does
-- nothing, because `main` keeps its queries in `runtime/queries/`, which is one
-- directory below anything on the runtimepath.
--
-- That failure is invisible in normal editing: LSP semantic tokens colour the
-- buffer, so Go looks fine while treesitter contributes zero captures. It only
-- shows up somewhere without an LSP attached -- the review preview in
-- lua/agent/inbox.lua, which renders plain white.
--
-- If you ever move to Neovim 0.12, `main` becomes the right branch again.
local ensure_installed = {
  'bash',
  'c',
  'css',
  'diff',
  'dockerfile',
  'go',
  'gomod',
  'gosum',
  'gowork',
  'gitcommit',
  'gitignore',
  'html',
  'javascript',
  'jsdoc',
  'json',
  'lua',
  'luadoc',
  'make',
  'markdown',
  'markdown_inline',
  'python',
  'query',
  'regex',
  'sql',
  'terraform',
  'toml',
  'tsx',
  'typescript',
  'vim',
  'vimdoc',
  'yaml',
}

return {
  {
    'nvim-treesitter/nvim-treesitter',
    branch = 'master',
    lazy = false,
    build = ':TSUpdate',
    main = 'nvim-treesitter.configs',
    opts = {
      ensure_installed = ensure_installed,
      -- Pick up a parser for a filetype that isn't in the list above rather than
      -- leaving that buffer unhighlighted.
      auto_install = true,
      highlight = {
        enable = true,
        -- Running the old regex syntax underneath treesitter double-highlights
        -- and is slower; treesitter alone is the point.
        additional_vim_regex_highlighting = false,
      },
      -- Deliberately off: treesitter's indentexpr returns 0 for every line in Go
      -- (verified with `gg=G`), which silently replaces Neovim's own gofmt-aware
      -- indent with nothing. The builtin per-language indent files are better
      -- maintained and correct, so they stay.
      indent = { enable = false },
    },
    config = function(_, opts)
      require('nvim-treesitter.configs').setup(opts)

      -- Folds available but open by default; `zc` to close one.
      vim.o.foldmethod = 'expr'
      vim.o.foldexpr = 'v:lua.vim.treesitter.foldexpr()'
      vim.o.foldlevel = 99
      vim.o.foldtext = ''
    end,
  },

  -- Keeps the enclosing function/class pinned to the top of the window when you
  -- scroll past its opening line.
  {
    'nvim-treesitter/nvim-treesitter-context',
    event = { 'BufReadPost', 'BufNewFile' },
    opts = { max_lines = 3, multiline_threshold = 1 },
    keys = {
      { '<leader>uc', '<cmd>TSContextToggle<CR>', desc = 'Toggle sticky context' },
    },
  },
}
