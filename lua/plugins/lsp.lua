-- LSP on Neovim 0.11's native API: mason installs the servers, mason-lspconfig
-- calls vim.lsp.enable() for each installed one, and nvim-lspconfig supplies the
-- per-server defaults (cmd, filetypes, root markers).
--
-- To add a language: put its server name in `servers` below and restart. Run
-- :Mason to browse what's available.

local servers = {
  'lua_ls',
  'gopls',
  'ts_ls', -- TypeScript / JavaScript
  'eslint',
  'jsonls',
  'yamlls',
  'bashls',
  'pyright',
  'ruff', -- Python lint + format
  'terraformls',
  'dockerls',
  'docker_compose_language_service',
  'tailwindcss',
  'cssls',
  'html',
  'marksman', -- Markdown
}

return {
  {
    'neovim/nvim-lspconfig',
    event = { 'BufReadPre', 'BufNewFile' },
    dependencies = {
      { 'mason-org/mason.nvim', opts = { ui = { border = 'rounded' } } },
      'mason-org/mason-lspconfig.nvim',
      { 'j-hui/fidget.nvim', opts = {} }, -- LSP progress in the corner
    },
    config = function()
      -- Applies to every server: advertise the completion capabilities blink.cmp
      -- adds on top of Neovim's builtin client.
      local capabilities = vim.lsp.protocol.make_client_capabilities()
      local ok, blink = pcall(require, 'blink.cmp')
      if ok then
        capabilities = blink.get_lsp_capabilities(capabilities)
      end
      vim.lsp.config('*', { capabilities = capabilities })

      -- [[ Per-server overrides ]]
      vim.lsp.config('lua_ls', {
        settings = {
          Lua = {
            completion = { callSnippet = 'Replace' },
            workspace = { checkThirdParty = false },
            -- This config file is the main Lua we write; teach the server about
            -- `vim` so it stops flagging it as undefined.
            diagnostics = { globals = { 'vim' } },
            telemetry = { enable = false },
          },
        },
      })

      vim.lsp.config('gopls', {
        settings = {
          gopls = {
            gofumpt = true,
            usePlaceholders = true,
            staticcheck = true,
            analyses = {
              unusedparams = true,
              unusedwrite = true,
              nilness = true,
              shadow = false,
            },
            hints = {
              assignVariableTypes = true,
              compositeLiteralFields = true,
              constantValues = true,
              functionTypeParameters = true,
              parameterNames = true,
              rangeVariableTypes = true,
            },
          },
        },
      })

      vim.lsp.config('yamlls', {
        settings = {
          yaml = {
            keyOrdering = false, -- don't demand alphabetical keys
            schemaStore = { enable = true },
          },
        },
      })

      vim.lsp.config('ts_ls', {
        settings = {
          typescript = {
            inlayHints = {
              includeInlayParameterNameHints = 'literals',
              includeInlayFunctionLikeReturnTypeHints = true,
            },
          },
        },
      })

      -- Tailwind's server advertises a very broad filetype list, so by default it
      -- spins up in plain markdown and TypeScript files that have nothing to do
      -- with Tailwind. Only attach where there's actually a config.
      vim.lsp.config('tailwindcss', {
        root_dir = function(bufnr, on_dir)
          local found = vim.fs.find(function(name)
            return name:match '^tailwind%.config%.[cm]?[jt]s$'
          end, { path = vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr)), upward = true, type = 'file' })[1]
          if found then
            on_dir(vim.fs.dirname(found))
          end
        end,
      })

      require('mason-lspconfig').setup {
        ensure_installed = servers,
        -- Enable exactly the servers listed above, not everything Mason happens
        -- to have installed — otherwise leftovers from a previous config attach
        -- too and you get duplicate diagnostics (e.g. jedi alongside pyright).
        automatic_enable = servers,
      }

      -- [[ Buffer-local keymaps, bound once a server attaches ]]
      vim.api.nvim_create_autocmd('LspAttach', {
        group = vim.api.nvim_create_augroup('lsp_attach', { clear = true }),
        callback = function(event)
          local function map(keys, fn, desc, mode)
            vim.keymap.set(mode or 'n', keys, fn, { buffer = event.buf, desc = 'LSP: ' .. desc })
          end

          local builtin = require 'telescope.builtin'

          -- Neovim 0.11 already binds grn (rename), gra (code action), grr
          -- (references), gri (implementation), gO (symbols) and K (hover).
          -- These add the pickers and the definition jumps on top.
          map('gd', builtin.lsp_definitions, 'Goto definition')
          map('gD', vim.lsp.buf.declaration, 'Goto declaration')
          map('gy', builtin.lsp_type_definitions, 'Goto type definition')
          map('grr', builtin.lsp_references, 'References')
          map('gri', builtin.lsp_implementations, 'Implementations')
          map('<leader>cs', builtin.lsp_document_symbols, 'Document symbols')
          map('<leader>cS', builtin.lsp_dynamic_workspace_symbols, 'Workspace symbols')
          map('<leader>cr', vim.lsp.buf.rename, 'Rename')
          map('<leader>ca', vim.lsp.buf.code_action, 'Code action', { 'n', 'x' })
          map('<C-s>', vim.lsp.buf.signature_help, 'Signature help', 'i')

          local client = vim.lsp.get_client_by_id(event.data.client_id)
          if not client then
            return
          end

          -- Highlight other occurrences of whatever is under the cursor, and
          -- clear them when it moves. Torn down on detach so the autocmds don't
          -- outlive the client.
          if client:supports_method(vim.lsp.protocol.Methods.textDocument_documentHighlight) then
            local group = vim.api.nvim_create_augroup('lsp_highlight_' .. event.buf, { clear = false })
            vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
              buffer = event.buf,
              group = group,
              callback = vim.lsp.buf.document_highlight,
            })
            vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
              buffer = event.buf,
              group = group,
              callback = vim.lsp.buf.clear_references,
            })
            vim.api.nvim_create_autocmd('LspDetach', {
              group = vim.api.nvim_create_augroup('lsp_detach_' .. event.buf, { clear = true }),
              buffer = event.buf,
              callback = function(detach)
                vim.lsp.buf.clear_references()
                vim.api.nvim_clear_autocmds { group = group, buffer = detach.buf }
              end,
            })
          end

          if client:supports_method(vim.lsp.protocol.Methods.textDocument_inlayHint) then
            map('<leader>ch', function()
              vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled { bufnr = event.buf }, { bufnr = event.buf })
            end, 'Toggle inlay hints')
          end
        end,
      })
    end,
  },

  -- Formatting, kept separate from the LSP so the formatter and the language
  -- server can be chosen independently.
  {
    'stevearc/conform.nvim',
    event = 'BufWritePre',
    cmd = 'ConformInfo',
    keys = {
      {
        '<leader>cf',
        function()
          require('conform').format { async = true, lsp_format = 'fallback' }
        end,
        mode = { 'n', 'v' },
        desc = 'Format buffer',
      },
    },
    opts = {
      notify_on_error = false,
      formatters_by_ft = {
        lua = { 'stylua' },
        go = { 'goimports', 'gofumpt' },
        python = { 'ruff_organize_imports', 'ruff_format' },
        javascript = { 'prettierd', 'prettier', stop_after_first = true },
        javascriptreact = { 'prettierd', 'prettier', stop_after_first = true },
        typescript = { 'prettierd', 'prettier', stop_after_first = true },
        typescriptreact = { 'prettierd', 'prettier', stop_after_first = true },
        json = { 'prettierd', 'prettier', stop_after_first = true },
        jsonc = { 'prettierd', 'prettier', stop_after_first = true },
        yaml = { 'prettierd', 'prettier', stop_after_first = true },
        markdown = { 'prettierd', 'prettier', stop_after_first = true },
        html = { 'prettierd', 'prettier', stop_after_first = true },
        css = { 'prettierd', 'prettier', stop_after_first = true },
        sh = { 'shfmt' },
        bash = { 'shfmt' },
        terraform = { 'terraform_fmt' },
        hcl = { 'terraform_fmt' },
      },
      format_on_save = function(bufnr)
        -- `:FormatDisable` sets these; useful in a repo whose style you don't own.
        if vim.g.disable_autoformat or vim.b[bufnr].disable_autoformat then
          return
        end
        return { timeout_ms = 1000, lsp_format = 'fallback' }
      end,
    },
    init = function()
      vim.api.nvim_create_user_command('FormatDisable', function(args)
        if args.bang then
          vim.b.disable_autoformat = true -- buffer only
        else
          vim.g.disable_autoformat = true
        end
      end, { desc = 'Disable format-on-save (! for this buffer only)', bang = true })

      vim.api.nvim_create_user_command('FormatEnable', function()
        vim.b.disable_autoformat = false
        vim.g.disable_autoformat = false
      end, { desc = 'Re-enable format-on-save' })

      vim.keymap.set('n', '<leader>uf', function()
        vim.g.disable_autoformat = not vim.g.disable_autoformat
        vim.notify('Format on save: ' .. tostring(not vim.g.disable_autoformat))
      end, { desc = 'Toggle format on save' })
    end,
  },

  -- Installs the formatters above (and anything else non-LSP) via Mason.
  {
    'WhoIsSethDaniel/mason-tool-installer.nvim',
    dependencies = { 'mason-org/mason.nvim' },
    event = 'VeryLazy',
    opts = {
      -- goimports is deliberately absent: Mason's build of it fails on this
      -- machine, and `go install golang.org/x/tools/cmd/goimports@latest` puts
      -- it in ~/go/bin, which is already on PATH.
      ensure_installed = { 'stylua', 'gofumpt', 'prettierd', 'shfmt' },
      run_on_start = true,
    },
  },
}
