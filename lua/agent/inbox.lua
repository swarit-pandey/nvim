-- A queue of files Claude has edited, waiting for you to look at them.
--
-- Fed by the PostToolUse hook in ~/.claude/hooks/nvim-edit-log.sh, which appends
-- one line per edit. Nothing here is realtime; `<leader>av` asks "what has it
-- touched that I have not looked at yet".
--
-- Opening the pane is NOT reviewing. Entries persist until you mark them, so
-- glancing at the list and getting distracted does not lose the queue. Marking
-- everything is one key, so "clear each time I look" is still one keystroke away
-- -- the reverse would not be recoverable.
--
--   <CR>  jump to the file, at its first change
--   R     mark reviewed and move on
--   D     toggle removals shown inline
--   A     mark everything reviewed

local M = {}

M.config = {
  -- Lines of surrounding code kept around each change in the preview. Enough to
  -- see the enclosing function signature, not so much that you scroll.
  context = 4,
}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local function state_dir()
  local base = vim.env.XDG_STATE_HOME or (vim.uv.os_homedir() .. '/.local/state')
  return base .. '/nvim/agent-inbox'
end

--- Git root of the current buffer, falling back to cwd. Must match the slug the
--- hook computes, or the two look at different logs and the list comes up empty.
---
--- Resolved from the buffer's own directory rather than nvim's cwd: with one nvim
--- open on several worktrees, cwd is wherever it started and would point at the
--- wrong log entirely.
local function project_root()
  local dir = vim.fn.expand '%:p:h'
  if dir == '' or vim.fn.isdirectory(dir) == 0 then
    dir = vim.uv.cwd()
  end
  local out = vim.fn.systemlist { 'git', '-C', dir, 'rev-parse', '--show-toplevel' }
  if vim.v.shell_error == 0 and out[1] and out[1] ~= '' then
    return out[1]
  end
  return vim.uv.cwd()
end

local function slug(root)
  return (root:gsub('^/', ''):gsub('/', '-'))
end

--- Root and its log file.
---
--- `root` is a parameter, not something recomputed here, because everything after
--- the picker opens runs with the telescope *prompt* buffer current -- and that
--- buffer has no name, so project_root() would fall back to nvim's cwd. With one
--- nvim across several worktrees that is a different repo's log, and the actions
--- would silently mark the wrong files.
local function paths(root)
  root = root or project_root()
  return root, ('%s/%s.jsonl'):format(state_dir(), slug(root))
end

--- Everything the hook has logged, collapsed to one entry per file with its most
--- recent edit and a count.
local function read_log(file)
  local seen = {}
  local fd = io.open(file, 'r')
  if not fd then
    return seen
  end
  for line in fd:lines() do
    local ok, entry = pcall(vim.json.decode, line)
    if ok and type(entry) == 'table' and entry.path then
      local e = seen[entry.path]
      if e then
        e.count = e.count + 1
        e.at = math.max(e.at, entry.at or 0)
      else
        seen[entry.path] = { path = entry.path, at = entry.at or 0, count = 1, tool = entry.tool }
      end
    end
  end
  fd:close()
  return seen
end

--- Paths that are never user code. An agent keeps notes under ~/.claude, and
--- those edits are logged with the project's cwd, so without this they show up as
--- review items for whatever repo happened to be open.
local function ignored(path)
  return path:find('/.claude/', 1, true) ~= nil
end

--- Where the PreToolUse hook stores "what you last saw" for a file. Keyed by a
--- sha256 of the absolute path so the filename is fixed-length; the hook computes
--- the identical digest with shasum.
local function seen_file(root, path)
  return ('%s/%s.seen/%s'):format(state_dir(), slug(root), vim.fn.sha256(path))
end

--- The content to diff against.
---
--- NOT a git ref. A commit does not mean reviewed -- the agent commits its own
--- work, and `git diff HEAD` then reports nothing while you have still never read
--- any of it. The baseline is the snapshot taken before the agent's first edit
--- since your last review, so it survives any number of commits and only moves
--- when *you* mark the file reviewed.
---
--- The commit this branch grew from, for the fallback baseline.
---
--- `origin/main` was hardcoded here, which is wrong in two directions: repos whose
--- default branch is `master` (this config's own) never resolve it, and a stale
--- fork's origin/main resolves to something meaningless. Ask git what the branch
--- actually tracks, and only then guess.
---
--- Shelling out three times per file was most of the cost of opening the picker,
--- so the answer is resolved once per root per refresh.
local base_cache = {}

local function branch_base(root)
  local hit = base_cache[root]
  if hit ~= nil then
    return hit or nil -- `false` means "asked already, no answer"
  end

  local function try(rev)
    if not rev or rev == '' then
      return nil
    end
    local out = vim.fn.systemlist { 'git', '-C', root, 'merge-base', rev, 'HEAD' }
    if vim.v.shell_error == 0 and out[1] and out[1] ~= '' then
      return out[1]
    end
  end

  -- What this branch is actually tracking is the only answer that is not a guess.
  local up = vim.fn.systemlist { 'git', '-C', root, 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}' }
  local base = vim.v.shell_error == 0 and try(up[1]) or nil

  -- Then the remote's own idea of its default branch.
  if not base then
    local head = vim.fn.systemlist { 'git', '-C', root, 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD' }
    base = vim.v.shell_error == 0 and try(head[1]) or nil
  end

  -- Then the usual suspects, for a repo with no remote HEAD set.
  if not base then
    base = try 'origin/main' or try 'origin/master'
  end

  base_cache[root] = base or false
  return base
end

--- The content to diff against.
---
---@return string[]|nil lines  nil when there is no baseline at all
---@return string source  'seen' | 'branch' | 'none'
local function baseline(root, entry)
  local snap = seen_file(root, entry.path)
  if vim.uv.fs_stat(snap) then
    local ok, lines = pcall(vim.fn.readfile, snap)
    if ok then
      return lines, 'seen'
    end
  end

  -- No snapshot: either the file was edited before this mechanism existed, or the
  -- hook did not fire. Fall back to what the branch started from, which is at
  -- least meaningful, and label it so the difference is visible.
  if entry.inRepo then
    local base = branch_base(root)
    if base then
      local out = vim.fn.systemlist { 'git', '-C', root, 'show', base .. ':' .. entry.rel }
      if vim.v.shell_error == 0 then
        return out, 'branch'
      end
      return {}, 'branch' -- added on this branch
    end
  end

  -- Genuinely nothing to compare against. The file is still listed -- it was
  -- edited, which is the thing you asked to be told about. Hiding it because we
  -- cannot draw a diff is the one behaviour that loses information silently.
  return nil, 'none'
end

--- Record the current content as "what you have now seen". This is what marking
--- reviewed means.
---
--- It WRITES a snapshot rather than deleting one. Deleting was the obvious move
--- and it was wrong: with no snapshot the next `pending()` falls through to the
--- branch-base fallback, every agent-edited file differs from the branch base, and
--- so every file you just reviewed came straight back. Writing the current content
--- makes the file stop matching, and the PreToolUse hook's `[ ! -e ]` guard leaves
--- it alone until the agent edits again -- which is exactly the documented
--- semantics of "the last time I saw this".
local function mark_seen(root, path)
  local snap = seen_file(root, path)
  vim.fn.mkdir(vim.fs.dirname(snap), 'p')

  -- Copied rather than readfile/writefile so the snapshot is byte-identical to
  -- what the hook would have taken with `cp`, trailing newline included.
  if not vim.uv.fs_copyfile(path, snap) then
    -- Gone from disk: there is nothing to have seen, and a stale snapshot would
    -- make a re-created file look unchanged.
    os.remove(snap)
  end
end

--- Files edited since you last marked them reviewed.
---
--- The comparison is per file and by timestamp, so a file you reviewed and the
--- agent then edited again comes back -- which is the behaviour you want, and the
--- reason this is not just a single global cursor.
function M.pending(root)
  local log
  root, log = paths(root)
  base_cache = {} -- one git resolution per refresh, not one per file

  local out = {}
  for path, entry in pairs(read_log(log)) do
    if vim.uv.fs_stat(path) and not ignored(path) then
      -- An agent running in this worktree can still edit files outside it (its
      -- own state, or another repo via --add-dir). `rel` is nil for those, and
      -- git operations against them are meaningless -- so record which side of
      -- the boundary the file is on instead of pretending everything is relative.
      entry.rel = vim.fs.relpath(root, path)
      entry.inRepo = entry.rel ~= nil
      entry.display = entry.rel or vim.fn.fnamemodify(path, ':~')

      -- Only list it if it actually differs from what you last saw. A file the
      -- agent touched and then reverted is not something to review.
      local before, source = baseline(root, entry)
      entry.before, entry.source = before, source
      if not before then
        -- No baseline to compare against. Still list it: it was edited, and that
        -- is the question this pane answers. `source` tells the row to say so.
        table.insert(out, entry)
      else
        -- Guarded: the agent can rename or delete this file while you are
        -- browsing, and an unguarded readfile takes the whole picker down with
        -- E484 rather than dropping one row.
        local ok, after = pcall(vim.fn.readfile, path)
        if ok and not vim.deep_equal(before, after) then
          table.insert(out, entry)
        end
      end
    end
  end

  table.sort(out, function(a, b)
    return a.at > b.at -- newest first: that is what you have least context on
  end)
  return out, root
end

--- Drop the reviewed paths from the log, keeping every other line byte-for-byte.
---
--- Without this the log is append-only forever: it is re-parsed on every refresh,
--- and each entry that no longer has anything to show still costs a stat and a
--- diff. Written to a temp file and renamed so a crash mid-write cannot leave a
--- half-truncated log.
local function prune_log(log, paths_to_drop)
  local fd = io.open(log, 'r')
  if not fd then
    return
  end
  local keep = {}
  for line in fd:lines() do
    local ok, entry = pcall(vim.json.decode, line)
    if not (ok and type(entry) == 'table' and entry.path and paths_to_drop[entry.path]) then
      table.insert(keep, line)
    end
  end
  fd:close()

  local tmp = log .. '.tmp'
  local out = io.open(tmp, 'w')
  if not out then
    return
  end
  for _, line in ipairs(keep) do
    out:write(line, '\n')
  end
  out:close()
  os.rename(tmp, log)
end

--- Mark files reviewed: the snapshot becomes the current content, and the log
--- entries go away. Both halves matter -- the snapshot is what the *next* diff is
--- taken against, the log prune is what stops the queue growing forever.
function M.mark(list, root)
  local log
  root, log = paths(root)

  local dropped = {}
  for _, entry in ipairs(list) do
    mark_seen(root, entry.path)
    dropped[entry.path] = true
  end
  if next(dropped) then
    prune_log(log, dropped)
  end
end

---------------------------------------------------------------------------
-- Presentation
---------------------------------------------------------------------------

local ns = vim.api.nvim_create_namespace 'agent_inbox'

--- Show removals inline as virtual lines. Off by default so the preview reads as
--- code; `D` turns it into a diff.
local inline = false

local function ago(ts)
  local d = os.time() - ts
  if d < 60 then
    return d .. 's'
  elseif d < 3600 then
    return math.floor(d / 60) .. 'm'
  elseif d < 86400 then
    return math.floor(d / 3600) .. 'h'
  end
  return math.floor(d / 86400) .. 'd'
end

--- The file as HEAD has it. A file the agent created is absent there, so an empty
--- baseline is right: all of it is new.

local function join(lines)
  return #lines == 0 and '' or (table.concat(lines, '\n') .. '\n')
end

--- Changed regions between HEAD and the working copy, as
--- {start_a, count_a, start_b, count_b} with 1-based line numbers.
local function hunks(before, after)
  local ok, result = pcall(vim.diff, join(before), join(after), { result_type = 'indices', algorithm = 'histogram' })
  if not ok or type(result) ~= 'table' then
    return {}
  end
  return result
end

--- Where to hang a hunk's removed lines in the *after* buffer.
---
--- For a replacement (count_b > 0) the new lines start at start_b, so the removed
--- ones go above them. For a pure deletion vim.diff reports start_b as the line
--- the removal sits *after*: deleting "b" from a/b/c gives {2,1,1,0}, and the gap
--- belongs above after-line 2. Anchoring both cases at start_b - 1 drew every
--- deletion one line too high, and only looked correct at the top of a file where
--- the clamp cancelled the error out.
---
--- Pulled out of paint() and exported as `_deletion_anchor` purely so this is
--- testable -- it is the one piece of index arithmetic here that has already been
--- wrong once.
---@return integer row 0-based
---@return boolean above
local function deletion_anchor(start_b, count_b, nafter)
  if count_b > 0 then
    return math.max(start_b - 1, 0), true
  end
  if start_b > nafter - 1 then
    -- Deleted past the end of the file: no line left to sit above, so hang the
    -- removed lines under the last one.
    return math.max(nafter - 1, 0), false
  end
  return math.max(start_b, 0), true
end

M._deletion_anchor = deletion_anchor

local function stats(before, after)
  local added, removed = 0, 0
  for _, h in ipairs(hunks(before, after)) do
    removed = removed + h[2]
    added = added + h[4]
  end
  return added, removed
end

---------------------------------------------------------------------------
-- Preview: the code, with the agent's changes marked on it
---------------------------------------------------------------------------

--- Paint one file into a preview buffer.
---
--- Deliberately not a unified diff. A `git diff` dumped into a buffer with
--- `filetype=diff` only ever gets flat red/green and loses the language entirely.
--- Rendering the real file and marking the changed lines keeps full treesitter
--- highlighting, which is what makes the change readable in context.
---
---@return integer|nil first first changed line
---@return table regions regions worth showing
local function paint(bufnr, root, entry, ft)
  -- The entry's own absolute path. Rebuilding it as root .. "/" .. rel produced
  -- `/repo//abs/path` for anything outside the repo and crashed readfile.
  local ok, after = pcall(vim.fn.readfile, entry.path)
  if not ok then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'could not read ' .. entry.path })
    return nil, {}
  end
  local before = entry.before

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, after)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  -- treesitter directly rather than setting `filetype`: setting it would attach a
  -- language server to a throwaway preview buffer and pollute diagnostics.
  local lang = ft and vim.treesitter.language.get_lang(ft)
  if lang then
    pcall(vim.treesitter.start, bufnr, lang)
  end

  local first
  local regions = {}
  if not before then
    -- Outside the repo: show it, but do not invent a diff.
    return nil, {}
  end
  for _, h in ipairs(hunks(before, after)) do
    local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]

    -- Track what the change touches so everything else can be folded away.
    local lo = math.max(1, start_b - M.config.context)
    local hi = math.min(math.max(#after, 1), math.max(start_b + count_b - 1, start_b) + M.config.context)
    table.insert(regions, { lo, hi })

    -- Added or changed lines, tinted with a gutter bar.
    for i = 0, count_b - 1 do
      local row = start_b - 1 + i
      if row >= 0 and row < #after then
        first = first or (row + 1)
        vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
          hl_group = count_a > 0 and 'DiffChange' or 'DiffAdd',
          hl_eol = true,
          sign_text = '▎',
          sign_hl_group = count_a > 0 and 'DiffChange' or 'DiffAdd',
        })
      end
    end

    -- Removed lines, shown above where they used to be. This is the part that
    -- makes it a diff rather than a highlight, so it is opt-in via `D`.
    if inline and count_a > 0 then
      local virt = {}
      for i = 0, count_a - 1 do
        local text = before[start_a + i]
        if text then
          table.insert(virt, { { '  ' .. text, 'DiffDelete' } })
        end
      end
      local anchor, above = deletion_anchor(start_b, count_b, #after)
      first = first or (anchor + 1)
      if #virt > 0 then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, anchor, 0, {
          virt_lines = virt,
          virt_lines_above = above,
        })
      end
    end
  end

  -- Merge regions that overlap or nearly touch, so two nearby edits read as one
  -- block instead of being separated by a two-line fold.
  table.sort(regions, function(a, b)
    return a[1] < b[1]
  end)
  local merged = {}
  for _, r in ipairs(regions) do
    local last = merged[#merged]
    if last and r[1] <= last[2] + 3 then
      last[2] = math.max(last[2], r[2])
    else
      table.insert(merged, { r[1], r[2] })
    end
  end

  return first, merged
end

--- Collapse everything that did not change.
---
--- Folding rather than splicing the changed lines into a fresh buffer: treesitter
--- needs the whole file to parse, and a buffer of disjoint fragments highlights
--- as broken syntax. This keeps the parse intact and simply hides the rest.
local function fold_unchanged(winid, bufnr, regions)
  if not vim.api.nvim_win_is_valid(winid) then
    return
  end
  local total = vim.api.nvim_buf_line_count(bufnr)

  vim.api.nvim_win_call(winid, function()
    vim.wo.foldmethod = 'manual'
    vim.wo.foldenable = true
    vim.wo.foldlevel = 0
    vim.wo.foldcolumn = '0'
    vim.wo.foldtext = "v:lua.require'agent.inbox'.foldtext()"
    vim.cmd 'silent! normal! zE'

    if #regions == 0 then
      return
    end

    local cursor = 1
    local gaps = {}
    for _, r in ipairs(regions) do
      if r[1] > cursor then
        table.insert(gaps, { cursor, r[1] - 1 })
      end
      cursor = math.max(cursor, r[2] + 1)
    end
    if cursor <= total then
      table.insert(gaps, { cursor, total })
    end

    for _, g in ipairs(gaps) do
      -- A one or two line fold saves nothing and costs a line to say so.
      if g[2] - g[1] >= 2 then
        pcall(vim.cmd, ('silent! %d,%dfold'):format(g[1], g[2]))
      end
    end
  end)
end

function M.foldtext()
  local n = vim.v.foldend - vim.v.foldstart + 1
  return ('     ⋯ %d lines'):format(n)
end

--- Say so in the view, not in a notification that scrolls past.
---
--- Distinguishes the two states that look identical otherwise: nothing has been
--- recorded for this project at all (hook not firing, wrong directory), versus
--- everything recorded has been reviewed.
function M.show_empty(root)
  local _, log = paths(root)
  local logged = 0
  for _ in pairs(read_log(log)) do
    logged = logged + 1
  end

  -- Marking reviewed prunes the log, so an empty log no longer distinguishes
  -- "reviewed everything" from "the hook never fired". The snapshots do: one file
  -- under <slug>.seen/ per file you have ever reviewed here.
  local reviewed = 0
  local dir = ('%s/%s.seen'):format(state_dir(), slug(root))
  for _ in vim.fs.dir(dir) do
    reviewed = reviewed + 1
  end

  local lines
  if logged == 0 and reviewed == 0 then
    lines = {
      '  No agent edits recorded here',
      '',
      '  project   ' .. vim.fn.fnamemodify(root, ':~'),
      '',
      '  Nothing has been logged for this project. If Claude has',
      '  edited files here, check the PostToolUse hook in',
      '  ~/.claude/settings.json.',
    }
  else
    lines = {
      '  ✓  All reviewed',
      '',
      ('  %d file%s reviewed here, nothing left to look at.'):format(reviewed, reviewed == 1 and '' or 's'),
      '',
      '  Reopen this pane to pick up new edits — it does not',
      '  refresh on its own. Entries stay until you mark them;',
      '  committing does not clear them.',
    }
  end

  local width, height = 62, #lines
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' Claude edits ',
    title_pos = 'center',
  })
  vim.wo[win].winhl = 'Normal:NormalFloat'

  vim.api.nvim_buf_add_highlight(buf, 0, logged == 0 and 'WarningMsg' or 'DiffAdd', 0, 0, -1)
  for i = 2, #lines - 1 do
    vim.api.nvim_buf_add_highlight(buf, 0, 'Comment', i, 0, -1)
  end

  for _, key in ipairs { 'q', '<Esc>', '<CR>' } do
    vim.keymap.set('n', key, function()
      pcall(vim.api.nvim_win_close, win, true)
    end, { buffer = buf, nowait = true })
  end
end

---------------------------------------------------------------------------
-- The picker
---------------------------------------------------------------------------

function M.open()
  local ok_t = pcall(require, 'telescope')
  if not ok_t then
    vim.notify('telescope is required for the review picker', vim.log.levels.ERROR)
    return
  end

  local pickers = require 'telescope.pickers'
  local finders = require 'telescope.finders'
  local conf = require('telescope.config').values
  local previewers = require 'telescope.previewers'
  local actions = require 'telescope.actions'
  local action_state = require 'telescope.actions.state'
  local entry_display = require 'telescope.pickers.entry_display'

  -- Resolved once, here, while a real file is still the current buffer. Every
  -- refresh and every action below reuses it -- see paths().
  local root = project_root()

  local entries = M.pending(root)
  if #entries == 0 then
    M.show_empty(root)
    return
  end

  local width = 20
  for _, e in ipairs(entries) do
    width = math.max(width, #e.display)
  end
  width = math.min(width, 52)

  local displayer = entry_display.create {
    separator = '  ',
    items = { { width = width }, { width = 9 }, { width = 8 }, { remaining = true } },
  }

  local function make(entry)
    local ok, after = pcall(vim.fn.readfile, entry.path)
    if not ok then
      after = {}
    end
    local before = entry.before
    local churnText, churnHl = '        —', 'Comment'
    if before then
      local added, removed = stats(before, after)
      churnText = ('+%d -%d'):format(added, removed)
      churnHl = entry.inRepo and 'DiffAdd' or 'Comment'
      -- '~' flags a fallback baseline (branch start, not a real snapshot), so an
      -- approximate number never looks authoritative.
      if entry.source == 'branch' then
        churnText = '~' .. churnText
      end
    elseif entry.source == 'none' then
      -- Listed, but we have no idea what changed. Say that rather than printing a
      -- dash that reads like "nothing changed".
      churnText, churnHl = '        ?', 'WarningMsg'
    end
    return {
      value = entry,
      ordinal = entry.display,
      path = entry.path,
      display = function()
        return displayer {
          { entry.display, entry.inRepo and 'Directory' or 'Comment' },
          { churnText, churnHl },
          { entry.count == 1 and '1 edit' or (entry.count .. ' edits'), 'Comment' },
          { ago(entry.at), 'Comment' },
        }
      end,
    }
  end

  local function finder()
    return finders.new_table { results = M.pending(root), entry_maker = make }
  end

  local previewer = previewers.new_buffer_previewer {
    title = 'Changes since you last reviewed',
    -- One preview buffer per file, reused as you move up and down.
    get_buffer_by_name = function(_, entry)
      return entry.value.path
    end,
    define_preview = function(self, entry)
      -- Guarded: telescope calls this on every selection change, so an error here
      -- does not fail once -- it fires repeatedly and the picker reads as totally
      -- broken. One unreadable file should degrade to a message, not take the
      -- feature down.
      local ft = vim.filetype.match { filename = entry.value.path } or ''
      local ok, first, regions = pcall(paint, self.state.bufnr, root, entry.value, ft)
      if not ok then
        pcall(vim.api.nvim_buf_set_lines, self.state.bufnr, 0, -1, false, {
          'preview failed for ' .. tostring(entry.value.path),
          '',
          tostring(first),
        })
        return
      end

      -- Deferred, and this is load-bearing. Telescope *schedules* attaching the
      -- new buffer to the preview window but calls define_preview synchronously,
      -- so right now the window still shows the previous entry -- folds created
      -- here would be built against the wrong buffer and then discarded. It also
      -- forces foldlevel=100 and signcolumn=no, both of which have to be undone
      -- after the fact rather than before.
      local winid, bufnr = self.state.winid, self.state.bufnr
      vim.schedule(function()
        if not vim.api.nvim_win_is_valid(winid) or vim.api.nvim_win_get_buf(winid) ~= bufnr then
          return
        end
        vim.wo[winid].signcolumn = 'yes:1' -- telescope turns it off; the ▎ bars need it
        fold_unchanged(winid, bufnr, regions)
        -- Land on the first change: in a long file the edit is nowhere near the top.
        if first then
          pcall(vim.api.nvim_win_set_cursor, winid, { first, 0 })
          vim.api.nvim_win_call(winid, function()
            vim.cmd 'normal! zz'
          end)
        end
      end)
    end,
  }

  pickers
    .new({}, {
      prompt_title = ('Claude edited %d file%s'):format(#entries, #entries == 1 and '' or 's'),
      -- Reading code needs width. The list is short names and two numbers, so
      -- the default even split wastes most of the screen on it.
      layout_strategy = 'horizontal',
      layout_config = { width = 0.95, height = 0.9, preview_width = 0.68, prompt_position = 'top' },
      -- Normal mode from the start. This is a browse-and-act picker, not a
      -- search one, so R/D/A should be plain keys -- and binding letters in
      -- insert mode would make them untypeable in the filter. Press `i` or `/`
      -- to filter.
      initial_mode = 'normal',
      finder = finder(),
      sorter = conf.generic_sorter {},
      previewer = previewer,
      attach_mappings = function(bufnr, map)
        -- Jump: open the file at the first change.
        actions.select_default:replace(function()
          local sel = action_state.get_selected_entry()
          actions.close(bufnr)
          if not sel then
            return
          end
          vim.cmd('edit ' .. vim.fn.fnameescape(sel.value.path))
          local before = sel.value.before
          local h = before and hunks(before, vim.api.nvim_buf_get_lines(0, 0, -1, false))[1]
          if h then
            pcall(vim.api.nvim_win_set_cursor, 0, { math.max(h[3], 1), 0 })
            vim.cmd 'normal! zz'
          end
        end)

        -- Reviewed: drop it and stay put. The list shrinks under the cursor, so
        -- the next file is already selected.
        map('n', 'R', function()
          local sel = action_state.get_selected_entry()
          if not sel then
            return
          end
          M.mark({ sel.value }, root)
          local picker = action_state.get_current_picker(bufnr)
          local left = M.pending(root)
          if #left == 0 then
            actions.close(bufnr)
            vim.notify 'All reviewed'
            return
          end
          picker:refresh(finders.new_table { results = left, entry_maker = make }, { reset_prompt = false })
        end, { desc = 'Mark reviewed' })

        map('n', 'A', function()
          -- Counted from what is on screen now, not from `entries` -- that is the
          -- list as it was when the picker opened, and R may have shrunk it since.
          local list = M.pending(root)
          M.mark(list, root)
          actions.close(bufnr)
          vim.notify(('Marked %d file%s reviewed'):format(#list, #list == 1 and '' or 's'))
        end, { desc = 'Mark all reviewed' })

        -- Inline diff: reveal what was removed, in place.
        map('n', 'D', function()
          inline = not inline
          local picker = action_state.get_current_picker(bufnr)
          picker:refresh(finder(), { reset_prompt = false })
        end, { desc = 'Toggle inline diff' })

        map('n', 'q', function()
          actions.close(bufnr)
        end, { desc = 'Close' })

        return true
      end,
    })
    :find()
end

--- Forget everything, e.g. after reviewing outside this pane.
function M.clear()
  local root = project_root()
  local entries = M.pending(root)
  M.mark(entries, root)
  vim.notify(('Cleared %d pending file%s'):format(#entries, #entries == 1 and '' or 's'))
end

-- NOTE: state for deleted worktrees is still never cleaned up. The obvious sweep
-- -- reverse the slug, delete anything whose root is gone -- is unsafe, because
-- the slug is not reversible: `/Users/swarit/agent-api` slugs to
-- `Users-swarit-agent-api`, which reverses to `/Users/swarit/agent/api`, which
-- does not exist. That sweep deletes live state for every repo with a hyphen in
-- its name. Doing this properly needs the slug to carry a hash of the root
-- (mirrored in both hooks), so it waits for that.

function M.setup()
  vim.keymap.set('n', '<leader>av', M.open, { desc = 'Review files Claude edited' })
  vim.api.nvim_create_user_command('ClaudeEdits', M.open, { desc = 'Files Claude edited since your last review' })
  vim.api.nvim_create_user_command('ClaudeEditsClear', M.clear, { desc = 'Mark all edited files reviewed' })
end

return M
