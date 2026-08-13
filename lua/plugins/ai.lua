-- Claude Code, wired in the same way the official VS Code / JetBrains extensions
-- are: this plugin runs a small WebSocket server implementing Claude Code's IDE
-- protocol, and the `claude` CLI connects back to it.
--
-- Authentication is whatever your `claude` CLI is already logged in as — your
-- company account works as-is. No API key is read or needed by this plugin.
--
-- What the IDE connection buys over just running `claude` in a terminal:
--   * your visual selection and current file are sent as live context
--   * @-mentions of files straight from the tree or a picker
--   * edits arrive as a real Neovim diff you accept or reject per-hunk
return {
  -- Claude's replies -- the fix summaries in `:ClaudeFixLog` (lua/agent/lint.lua)
  -- chief among them -- are markdown. Without this, `**bold**`, `` `code` `` and
  -- `- ` bullets show up as literal characters: filetype=markdown alone only gets
  -- you syntax colors, not concealment/rendering.
  {
    'MeanderingProgrammer/render-markdown.nvim',
    ft = 'markdown',
    opts = {},
  },

  {
    'coder/claudecode.nvim',
    dependencies = { 'folke/snacks.nvim' },
    -- Loaded shortly after startup rather than purely on demand, so the IDE
    -- websocket server is listening and its ~/.claude/ide/<port>.lock exists
    -- before anything looks for it. A `claude --ide` started in a sibling tmux
    -- pane discovers the editor through that lock file; if the plugin only loaded
    -- when a keymap was pressed, there would be nothing to discover.
    event = 'VeryLazy',
    cmd = {
      'ClaudeCode',
      'ClaudeCodeFocus',
      'ClaudeCodeSelectModel',
      'ClaudeCodeAdd',
      'ClaudeCodeSend',
      'ClaudeCodeTreeAdd',
      'ClaudeCodeStatus',
      'ClaudeCodeStart',
      'ClaudeCodeStop',
      'ClaudeCodeDiffAccept',
      'ClaudeCodeDiffDeny',
    },
    opts = {
      auto_start = true, -- start the IDE server with Neovim so `claude` can attach
      terminal_cmd = nil, -- nil = plain `claude` from PATH
      track_selection = true,
      focus_after_send = false,
      terminal = {
        split_side = 'right',
        split_width_percentage = 0.35,
        -- Native rather than snacks: the agent view in lua/agent/view.lua moves
        -- the terminal buffer into its own tabpage, and the native provider
        -- tolerates that (it re-finds its window by scanning for the buffer).
        -- Snacks owns its window and would fight over placement.
        provider = 'native',
        auto_close = false, -- keep the session visible after Claude finishes
        auto_insert = true,
      },
      diff_opts = {
        layout = 'vertical',
        open_in_new_tab = false,
        auto_resize_terminal = true,
      },
    },
    keys = {
      { '<leader>a', nil, desc = 'AI / Claude' },
      { '<leader>ac', '<cmd>ClaudeCode<CR>', desc = 'Toggle Claude' },
      { '<leader>af', '<cmd>ClaudeCodeFocus<CR>', desc = 'Focus Claude' },
      { '<leader>ar', '<cmd>ClaudeCode --resume<CR>', desc = 'Resume a session' },
      { '<leader>aC', '<cmd>ClaudeCode --continue<CR>', desc = 'Continue last session' },
      { '<leader>am', '<cmd>ClaudeCodeSelectModel<CR>', desc = 'Select model' },
      { '<leader>ab', '<cmd>ClaudeCodeAdd %<CR>', desc = 'Add current buffer as context' },
      { '<leader>as', '<cmd>ClaudeCodeSend<CR>', mode = 'v', desc = 'Send selection to Claude' },
      -- Same key inside the file tree adds the file under the cursor.
      { '<leader>as', '<cmd>ClaudeCodeTreeAdd<CR>', ft = { 'neo-tree', 'oil', 'netrw' }, desc = 'Add file to Claude' },
      { '<leader>aa', '<cmd>ClaudeCodeDiffAccept<CR>', desc = 'Accept diff' },
      { '<leader>ad', '<cmd>ClaudeCodeDiffDeny<CR>', desc = 'Reject diff' },
      { '<leader>a?', '<cmd>ClaudeCodeStatus<CR>', desc = 'Connection status' },
    },
  },
}
