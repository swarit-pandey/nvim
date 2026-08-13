# nvim

Personal Neovim config. Leader is `<Space>` — press it and wait; which-key shows
everything available. `<leader>K` lists every mapping, `<leader>sk` searches them.

## Layout

```
init.lua                 entry point
lua/config/
  options.lua            vim options, diagnostics
  keymaps.lua            non-plugin keymaps
  autocmds.lua           per-filetype indentation, yank highlight, etc.
  lazy.lua               plugin manager bootstrap
lua/plugins/             one file per concern, each returns a lazy.nvim spec
  colorscheme.lua        Ghostty theme bridge
  ui.lua                 which-key, lualine, icons, snacks, dashboard
  telescope.lua          pickers
  lsp.lua                LSP servers + conform formatting
  completion.lua         blink.cmp
  treesitter.lua         parsers, highlighting, sticky context
  explorer.lua           neo-tree sidebar
  ai.lua                 Claude Code
  editor.lua             git, mini.nvim, todo-comments
lua/notes/init.lua       reads ~/notes/ specs and ledgers in a float, in place
lua/ghostty/theme.lua    reads Ghostty's theme, generates the colorscheme
```

## Theme

There is no colorscheme plugin. On startup the config reads Ghostty's config,
resolves the active theme file, and translates its 16 ANSI colours plus
background/foreground into a base16 palette that `mini.base16` expands into full
highlights.

Change the theme in Ghostty and Neovim follows — the config file is watched, and
it re-checks on focus. `:GhosttyTheme` forces a reload; `:GhosttyThemeInfo` shows
what was resolved.

Handled: `theme = Name` with loose name matching (`Melange_dark` finds the file
`Melange Dark`), `theme = dark:A,light:B` following macOS appearance, and
`palette`/`background`/`foreground` overrides set directly in the config.

Neovim's `:terminal` colours are set from the raw Ghostty palette rather than the
base16 approximation, so embedded terminals — including Claude Code — render
identically to a normal Ghostty pane.

## Two views

`<C-q>` flips between a **code view** and a full-window **agent view**, the way
Cursor's agent pane works.

They're separate tabpages, which is what makes the switch free: each tabpage owns
its window layout, so your splits survive going to the agent and back, and the
agent keeps its scrollback and any in-flight work. Nothing is respawned — both
views point at the same Claude process.

| Key | Action |
| --- | --- |
| `<C-q>` | Toggle code ⇄ agent. Same key both directions, works in terminal mode |
| `<leader>av` | Same toggle, if your hand is already on `<leader>` |
| `<leader>A` | Same again, kept for muscle memory |
| `<leader>aS` | Visual mode: send the selection *and* jump to the agent view |
| `:AgentView` / `:CodeView` | Same thing as commands |

`<C-q>` shadows Neovim's alias for blockwise visual; `<C-v>` is the real binding
for that and is untouched.

`<Esc>` is deliberately not bound — Claude uses it to interrupt a running turn.

This is separate from `<leader>ac`, which is still the 35% side split for when you
want the agent and your code visible at once. Both drive the same session.

Implementation is in `lua/agent/view.lua`. Closing the agent tab by hand is fine;
the next `<leader>A` rebuilds it and reattaches to the running session.

## Reviewing what the agent wrote

Two stages, because they answer different questions.

### In-flight: Claude's proposal

Claude's edits arrive as a native Vim diff — your file on the left, the proposal
on the right — and nothing touches disk until you say so. A winbar spells out the
keys.

| Key | Effect |
| --- | --- |
| `]c` / `[c` | Next / previous changed hunk |
| `<leader>ah` | **Reject just this hunk** — restores your version, keeps the rest |
| `<leader>aH` | Undo that, re-apply the hunk from the proposal |
| `<leader>aa` | Accept — writes the proposal buffer *as it now stands* |
| `<leader>ad` | Discard everything |

Partial acceptance works because the proposal buffer is editable and accept saves
its current contents. So `]c` through the hunks, `<leader>ah` the ones you don't
want, then `<leader>aa`.

### After the fact: review everything

| Key | Effect |
| --- | --- |
| `<leader>gv` | Open/close the review — file panel plus side-by-side diffs |
| `]c` / `[c` | Move between hunks |
| `<leader>gr` | Reject a hunk (gitsigns `reset_hunk`) |
| `<leader>gp` | Preview a hunk inline |
| `<leader>gl` | History of the current file |

This diffs the working tree, so it catches changes however they were written —
through the proposal diff, through Claude's own file tools, or by you.

Rejecting a hunk edits the **buffer**; `:w` to persist it.

## Fixing diagnostics with Claude

| Key | Scope |
| --- | --- |
| `<leader>ax` | Every actionable diagnostic in the **current buffer** |
| `<leader>al` | Just the diagnostic under the cursor |

Scope is always one file — there is no project-wide variant on purpose.

Collects from `vim.diagnostic`, so whatever already reports into Neovim is what
gets sent (gopls, eslint, ruff, tsc) with no per-linter wiring. Hints and info
are dropped; only errors and warnings go over.

**Two layers of guard rails**, in `lua/agent/lint.lua`:

*Filtered out before Claude sees them* (`config.skip_patterns`) — deprecations,
`undefined:`, `undeclared name`, `could not import`, `has no field or method`
and friends. These need changes in other files, or their "fix" is a dependency
decision.

*Stated as hard rules in the prompt* — edit only this file, never add an import
or dependency, skip anything not fixable in-file, don't migrate off deprecated
APIs, don't refactor or reformat, don't run build/test commands.

### How it runs

`claude -p` in the **background**. No window opens, focus never leaves your
buffer, and the process exits on its own — there is no session to close, and your
interactive agent session (and its model) is untouched.

Tool access is locked down by CLI flags, not prompt wording:
`--allowed-tools Read,Edit` means no Bash (can't run builds or tests) and no
Write (can't create files). `--model sonnet` keeps it on a mid-tier model.

The file is snapshotted in memory first, then when the run finishes you get a
diff of exactly what changed:

| Key | Effect |
| --- | --- |
| `]c` / `[c` | Next / previous hunk |
| `<leader>ah` | Reject this hunk |
| `<leader>aa` | Keep the rest, close the review |
| `<leader>ad` | Revert everything |
| `<leader>aL` | What Claude said it did (`:ClaudeFixLog`) |

If it touches a file it wasn't asked to, you get a warning naming it — checked
against `git status` taken before the run.

Note that `<leader>aa` writes the buffer, which runs **format-on-save**. For Go
that means `goimports` will strip an unused import again even if you rejected its
removal — the formatter gets the last word, as it does on any save.

## Claude Code

`coder/claudecode.nvim` runs the same IDE protocol the official VS Code extension
uses. It shells out to your `claude` CLI, so it authenticates as whatever that CLI
is logged in as. **No API key involved.**

| Key | Action |
| --- | --- |
| `<leader>ac` | Toggle the Claude pane |
| `<leader>af` | Focus it |
| `<leader>ar` / `<leader>aC` | Resume a session / continue the last one |
| `<leader>as` (visual) | Send the selection |
| `<leader>as` (in neo-tree) | Add the file under the cursor |
| `<leader>ab` | Add the current buffer as context |
| `<leader>am` | Pick a model |
| `<leader>aa` / `<leader>ad` | Accept / reject a proposed diff |
| `<leader>a?` | Connection status |

Edits come back as a real Neovim diff you accept or reject, and your cursor
selection is sent as live context.

## Reading the notes agents write

Agents write specs and ledgers to `~/notes/`. Reading one used to mean leaving
the agent view — or a whole new Ghostty tab, and a second editor with no idea
about this worktree. `lua/notes/init.lua` puts the file in a **float over
whatever is underneath**, agent included, so nothing about your layout moves.

| Key | Opens |
| --- | --- |
| `<C-g>` (in the agent terminal) | Specs — the whole point; no need to leave terminal mode first |
| `<leader>ns` | Specs |
| `<leader>nl` / `<leader>nt` | Ledgers / tasks and handoffs |
| `<leader>nn` | Everything in the notes directories |
| `<leader>nr` | Reopen the last one, no picker |
| `<leader>n/` | Grep the notes; the hit opens in the float on its line |
| `:Notes <group\|glob>` | Same picker — `:Notes ledger`, `:Notes *gitlab*.md` |

The picker always lists, and never picks for you: with several agents writing at
once, recency is not a good proxy for the one you meant. Each row carries its age
(`14m`, `21h`, `16d`) so you can tell competing specs apart at a glance, with the
newest first.

The buffer is the **real file**, not a scratch copy — annotate an agent's spec and
`:w` lands it, which is what you want when reviewing one before approving it.
`q` or `<Esc>` closes; if you came from the agent terminal you land back in it,
still in insert mode.

Where notes live is configurable, since that will not always be `~/notes`:

```lua
require('notes').setup {
  dirs = { '~/notes', '~/work/specs' },
  groups = { spec = { '*spec*.md', '*-design.md' } },
}
```

`$NOTES_DIR` overrides the default directory without editing the config.

## Floating terminal

`<C-/>` (or `<leader>tt`) toggles a bordered floating shell — for the one-off
`git log`, `go test ./...` or `wt list` that does not deserve a window. It floats
for the same reason the notes reader does: those are interruptions, and your
layout should come back untouched.

Bound in terminal mode too, so the same key closes it from inside. The shell
survives toggling, so a long-running command keeps going while it is hidden. The
title carries the working directory — with one Neovim per worktree, "which
checkout is this shell in" is the question you actually have while typing.

`<C-/>` is bound twice, as `<C-/>` and `<C-_>`. That chord has no single
encoding: terminals speaking the kitty keyboard protocol send one, everything
else sends the other, and binding only one makes the key silently dead half the
time.

## Filling in function parameters

`gopls` runs with `usePlaceholders`, so accepting `os.OpenFile` inserts
`OpenFile(name string, flag int, perm os.FileMode)` with each parameter as a
snippet placeholder. The first one arrives **selected**, so you type over it —
no deleting, no arrow keys.

| Key | Effect |
| --- | --- |
| type | Replaces the selected placeholder |
| `<Tab>` | Next placeholder (already selected — just type) |
| `<S-Tab>` | Previous placeholder |
| `<C-n>` / `<C-p>` | Cycle the completion menu, which Tab no longer touches mid-snippet |

Order matters in that keymap. With `select_next` ahead of `snippet_forward`,
filling a parameter re-opened the completion menu and the next Tab was eaten
highlighting a menu entry instead of jumping — `AAA<Tab>BBB` produced
`OpenFile(AAABBB, ...)`. Snippet-first makes Tab mean one thing while a snippet
is live.

For a call that already exists, mini.ai has argument textobjects:

| Key | Effect |
| --- | --- |
| `cia` | Change the argument under the cursor |
| `cina` | Change the **next** argument |
| `daa` | Delete an argument, comma included |
| `ci(` | Replace the whole argument list |

## Keymap overview

| Prefix | Area |
| --- | --- |
| `<leader>s` | Search (telescope) — `sf` files, `sg` grep, `sw` word, `sd` diagnostics, `sr` resume |
| `<leader>f` | Short aliases — `ff` files, `fg` grep, `fb` buffers, `fr` recent |
| `<leader><leader>` | Buffers |
| `<leader>e` / `<leader>E` | Explorer toggle / reveal current file |
| `<leader>g` | Git — hunks, blame, diff, commit pickers |
| `<leader>c` | Code — `cf` format, `ca` action, `cr` rename, `cs` symbols, `ch` inlay hints |
| `<leader>a` | Claude |
| `<leader>n` | Notes — `ns` specs, `nl` ledgers, `nt` tasks, `nr` reopen, `n/` grep |
| `<C-/>` / `<leader>tt` | Floating terminal (toggles from inside it too) |
| `<leader>x` | Diagnostics |
| `<leader>b` | Buffers |
| `<leader>u` | Toggles — `uf` format-on-save, `um` mouse, `uw` wrap, `ud` diagnostics |

`gd` definition, `gy` type definition, `grr` references, `gri` implementations,
`grn` rename, `gra` code action, `K` hover.

## Clipboard

`clipboard=unnamedplus` is on, so every yank and delete goes to the macOS
clipboard via `pbcopy`. `<leader>y` / `<leader>p` are explicit system-clipboard
versions. `<leader>d` deletes without touching the register, and `<leader>P` in
visual mode pastes over a selection without clobbering what you're pasting.

To select text with the mouse for Ghostty (rather than Neovim) to copy, hold
**Shift** while dragging, or toggle the mouse off with `<leader>um`.

Over SSH there is no `pbcopy`, so the config switches to OSC 52 automatically and
yanks still reach the local clipboard.

## Adding a language

Add the server name to the `servers` list at the top of `lua/plugins/lsp.lua` and
restart; Mason installs it. `:Mason` browses what's available, `:LspInfo` shows
what's attached. Formatters go in the `formatters_by_ft` table in the same file,
and their binaries in the `mason-tool-installer` list at the bottom.

## Debug log

Everything worth knowing while iterating on this config gets appended to
`~/.local/state/nvim/agent-debug.log`:

- notifications (tee'd off `vim.notify`, at every level)
- Neovim's own errors — `E492`, stack traces, LSP failures — polled out of
  `:messages`, which is where they land instead of `vim.notify`
- LSP attach, and every `DiagnosticChanged` with severity, source and message
- each background fix: root, file, argv, the full prompt, exit code, duration,
  and what Claude replied

| Command | |
| --- | --- |
| `:DevLog` | Open the log in a tab |
| `:DevLogMark <text>` | Annotate before trying something |
| `:DevLogClear` | Truncate it |
| `:DevLogPath` | Print the path |

`:DevLogMark about to press <leader>ax` before reproducing something makes the
entries that follow easy to find.

Turn it off with `vim.g.devlog_enabled = false`, or delete the
`require('config.devlog').setup()` line in `init.lua` — nothing depends on it.
It rotates at 1MB.

## Maintenance

`:Lazy` plugins · `:Mason` servers and tools · `:checkhealth` diagnosis ·
`:ConformInfo` formatter status.
