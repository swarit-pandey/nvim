return {
  {
    'saghen/blink.cmp',
    event = 'InsertEnter',
    version = '1.*', -- release tag ships the prebuilt fuzzy matcher, no Rust toolchain needed
    dependencies = { 'rafamadriz/friendly-snippets' },
    opts = {
      keymap = {
        -- <C-y> accepts, <C-n>/<C-p> or arrows cycle, <C-e> dismisses,
        -- <C-space> forces the menu open.
        preset = 'default',
        -- Enter accepts only a item you actually chose; see `preselect` below.
        -- Otherwise it falls through and just breaks the line.
        ['<CR>'] = { 'accept', 'fallback' },
        -- An active snippet wins over the menu, and that order matters.
        --
        -- With `select_next` first, filling in a parameter re-opens the
        -- completion menu (almost anything you type matches something), and the
        -- next Tab is eaten highlighting a menu entry instead of jumping to the
        -- next placeholder. Typing then appends to the parameter you just wrote:
        -- `AAA <Tab> BBB` produced `OpenFile(AAABBB, ...)` rather than
        -- `OpenFile(AAA, BBB, ...)`. Snippet-first makes Tab mean one thing
        -- whenever a snippet is live, which is when you most need it to.
        --
        -- The menu is not stranded: <C-n>/<C-p> and the arrows still cycle it,
        -- and <C-e> dismisses it. Tab still selects when no snippet is active,
        -- and indents when neither is.
        ['<Tab>'] = { 'snippet_forward', 'select_next', 'fallback' },
        ['<S-Tab>'] = { 'snippet_backward', 'select_prev', 'fallback' },
      },
      appearance = { nerd_font_variant = 'mono' },
      completion = {
        documentation = { auto_show = true, auto_show_delay_ms = 200 },
        menu = {
          draw = { treesitter = { 'lsp' } },
        },
        -- Show the menu as you type rather than only on <C-space>.
        trigger = { show_on_trigger_character = true },
        ghost_text = { enabled = false },
        list = {
          selection = {
            -- Nothing is selected until you press Tab. With the default
            -- (`preselect = true`) the first match is highlighted the moment the
            -- menu appears, so pressing Enter to start a new line silently
            -- inserts a completion you never asked for.
            preselect = false,
            auto_insert = false,
          },
        },
      },
      sources = {
        default = { 'lsp', 'path', 'snippets', 'buffer' },
      },
      signature = { enabled = true },
      fuzzy = { implementation = 'prefer_rust_with_warning' },
    },
    opts_extend = { 'sources.default' },
  },
}
