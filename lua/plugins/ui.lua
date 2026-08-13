-- A floating shell, for the one-off commands that do not deserve a window: a
-- `git log`, a `go test ./...`, a `wt list`. It floats rather than splitting
-- because those are interruptions -- you want your layout back untouched, which
-- is the same reason lua/notes/init.lua floats.
--
-- The title carries the working directory. With one Neovim per worktree and
-- several worktrees open at once, "which checkout is this shell in" is the
-- question you actually have while typing into it.
local function float_terminal()
  require('snacks').terminal.toggle(nil, {
    win = {
      position = 'float',
      border = 'rounded',
      title = ' ' .. vim.fn.fnamemodify(vim.fn.getcwd(), ':~') .. ' ',
      title_pos = 'center',
      -- Matching the notes float, so the two read as the same kind of overlay.
      width = 0.82,
      height = 0.86,
    },
  })
end

return {
  -- Press <space> and every binding under it appears. Nothing to memorise.
  {
    'folke/which-key.nvim',
    event = 'VeryLazy',
    opts = {
      preset = 'modern',
      -- 0 = the popup appears the instant you press the prefix, which is the
      -- point of having it. Raise this if it feels intrusive.
      delay = 0,
      icons = { mappings = vim.g.have_nerd_font },
      spec = {
        { '<leader>a', group = 'AI / Claude' },
        { '<leader>b', group = 'Buffer' },
        { '<leader>c', group = 'Code' },
        { '<leader>f', group = 'Find / File' },
        { '<leader>g', group = 'Git' },
        { '<leader>n', group = 'Notes' },
        { '<leader>t', group = 'Terminal' },
        { '<leader>s', group = 'Search' },
        { '<leader>u', group = 'UI toggles' },
        { '<leader>x', group = 'Diagnostics' },
        { 'g', group = 'Goto' },
        { ']', group = 'Next' },
        { '[', group = 'Previous' },
      },
    },
    keys = {
      {
        '<leader>?',
        function()
          require('which-key').show { global = false }
        end,
        desc = 'Keymaps for this buffer',
      },
      { '<leader>K', '<cmd>WhichKey<CR>', desc = 'All keymaps' },
    },
  },

  -- Icon provider. mini.icons stands in for nvim-web-devicons so telescope,
  -- neo-tree and lualine all pull from one source.
  {
    'echasnovski/mini.icons',
    version = false,
    lazy = true,
    opts = {},
    init = function()
      package.preload['nvim-web-devicons'] = function()
        require('mini.icons').mock_nvim_web_devicons()
        return package.loaded['nvim-web-devicons']
      end
    end,
  },

  {
    'nvim-lualine/lualine.nvim',
    event = 'VeryLazy',
    opts = function()
      return {
        options = {
          theme = 'auto', -- picks up the generated base16 highlights
          globalstatus = true,
          section_separators = '',
          component_separators = '│',
          disabled_filetypes = { statusline = { 'neo-tree' } },
        },
        sections = {
          lualine_a = { {
            'mode',
            fmt = function(s)
              return s:sub(1, 1)
            end,
          } },
          lualine_b = { 'branch', { 'diff', symbols = { added = '+', modified = '~', removed = '-' } } },
          lualine_c = {
            { 'filename', path = 1, symbols = { modified = ' ●', readonly = ' ' } },
          },
          lualine_x = {
            { 'diagnostics', symbols = { error = ' ', warn = ' ', info = ' ', hint = ' ' } },
            -- Which LSP servers are actually attached to this buffer.
            {
              function()
                local names = {}
                for _, client in ipairs(vim.lsp.get_clients { bufnr = 0 }) do
                  names[#names + 1] = client.name
                end
                return table.concat(names, ' ')
              end,
              icon = '',
            },
            'filetype',
          },
          lualine_y = { 'progress' },
          lualine_z = { 'location' },
        },
      }
    end,
  },

  -- Utility library. Required by claudecode.nvim for its terminal, and worth
  -- having for the nicer input/notification UI.
  {
    'folke/snacks.nvim',
    priority = 900,
    lazy = false,
    opts = {
      input = { enabled = true },
      notifier = { enabled = true, timeout = 2500 },
      quickfile = { enabled = true },
      bigfile = { enabled = true }, -- turn off expensive features in huge files

      -- Shown when Neovim starts with no file argument.
      dashboard = {
        enabled = true,
        preset = {
          -- Block-drawing characters rather than an ASCII figure: symmetric at
          -- any width and renders without a Nerd Font.
          header = table.concat({
            '',
            '█▄░█ █▀▀ █▀█ █░█ █ █▀▄▀█',
            '█░▀█ ██▄ █▄█ ▀▄▀ █ █░▀░█',
            '',
          }, '\n'),
          -- Explicit Telescope commands rather than snacks' own picker, since
          -- Telescope is what's configured here.
          --
          -- Icons are from the Material Design (U+F0xxx) range. The older
          -- three-digit Nerd Font codepoints were relocated in v3 and render as
          -- blanks.
          keys = {
            { icon = '󰈞 ', key = 'f', desc = 'Find file', action = ':Telescope find_files' },
            { icon = '󰍉 ', key = 'g', desc = 'Grep', action = ':Telescope live_grep' },
            { icon = '󰋚 ', key = 'r', desc = 'Recent files', action = ':Telescope oldfiles' },
            { icon = '󰉋 ', key = 'e', desc = 'Explorer', action = ':Neotree toggle left' },
            { icon = '󰐕 ', key = 'n', desc = 'New file', action = ':ene | startinsert' },
            { icon = '󰚩 ', key = 'c', desc = 'Claude', action = ':ClaudeCode' },
            { icon = '󰒓 ', key = 's', desc = 'Config', action = ':lua require("telescope.builtin").find_files({ cwd = vim.fn.stdpath("config") })' },
            { icon = '󰒲 ', key = 'l', desc = 'Lazy', action = ':Lazy' },
            { icon = '󰗼 ', key = 'q', desc = 'Quit', action = ':qa' },
          },
        },
        sections = {
          { section = 'header' },
          { section = 'keys', gap = 1, padding = 1 },
          -- Most-recently-used files from this project, if we're in one.
          { section = 'recent_files', cwd = true, title = 'Recent in project', icon = '󰋚 ', indent = 2, padding = 1, limit = 5 },
          { section = 'startup' },
        },
      },
    },
    keys = {
      {
        '<leader>uN',
        function()
          require('snacks').notifier.show_history()
        end,
        desc = 'Notification history',
      },

      -- Bound in terminal mode too, so the same key closes it from inside --
      -- otherwise you have to leave terminal mode first, which is exactly the
      -- friction a toggle is meant to remove.
      --
      -- Two keys for one chord: Ctrl+/ has no unambiguous encoding. Terminals
      -- that speak the kitty keyboard protocol (Ghostty does) send <C-/>;
      -- others send <C-_> (0x1F), which is what the same physical keypress
      -- arrives as over plain SSH or in a terminal without it. Binding one and
      -- not the other means the key silently does nothing half the time.
      { '<C-/>', float_terminal, mode = { 'n', 't' }, desc = 'Toggle floating terminal' },
      { '<C-_>', float_terminal, mode = { 'n', 't' }, desc = 'Toggle floating terminal' },

      -- Leader alias, so the terminal is discoverable in which-key rather than
      -- being a chord you have to already know about.
      { '<leader>tt', float_terminal, mode = { 'n', 't' }, desc = 'Toggle floating terminal' },
    },
  },
}
