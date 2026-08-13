-- Mirror the live Ghostty theme into Neovim.
--
-- Ghostty's config gives us a name (`theme = Melange Dark`) which resolves to a
-- theme file holding 16 ANSI colours plus background/foreground. That is exactly
-- the input mini.base16 wants, so we translate ANSI -> base16 and let it generate
-- the several hundred highlight groups.
--
-- Change the theme in Ghostty and Neovim follows: the config file is watched, and
-- we re-check on focus.

local M = {}

---------------------------------------------------------------------------
-- Colour helpers
---------------------------------------------------------------------------

local function to_rgb(hex)
  hex = hex:gsub('#', '')
  if #hex == 3 then -- expand #abc -> #aabbcc
    hex = hex:gsub('(%x)', '%1%1')
  end
  return tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
end

local function to_hex(r, g, b)
  local function clamp(v)
    return math.min(255, math.max(0, math.floor(v + 0.5)))
  end
  return string.format('#%02x%02x%02x', clamp(r), clamp(g), clamp(b))
end

--- Linear interpolation between two colours. `t` of 0 returns `a`, 1 returns `b`.
local function blend(a, b, t)
  local ar, ag, ab = to_rgb(a)
  local br, bg, bb = to_rgb(b)
  return to_hex(ar + (br - ar) * t, ag + (bg - ag) * t, ab + (bb - ab) * t)
end

--- Perceived brightness, 0 (black) to 1 (white).
local function luminance(hex)
  local r, g, b = to_rgb(hex)
  return (0.299 * r + 0.587 * g + 0.114 * b) / 255
end

---------------------------------------------------------------------------
-- Locating Ghostty's config and themes
---------------------------------------------------------------------------

local function exists(path)
  return path and vim.uv.fs_stat(path) ~= nil
end

local function first_existing(paths)
  for _, p in ipairs(paths) do
    if exists(p) then
      return p
    end
  end
end

local home = vim.uv.os_homedir()
local xdg = vim.env.XDG_CONFIG_HOME or (home .. '/.config')

function M.config_path()
  return first_existing {
    xdg .. '/ghostty/config',
    home .. '/Library/Application Support/com.mitchellh.ghostty/config',
  }
end

--- Directories that may hold theme files, user overrides first.
local function theme_dirs()
  local dirs = {
    xdg .. '/ghostty/themes',
    home .. '/Library/Application Support/com.mitchellh.ghostty/themes',
    '/Applications/Ghostty.app/Contents/Resources/ghostty/themes',
    '/usr/share/ghostty/themes',
    '/opt/homebrew/share/ghostty/themes',
  }
  return vim.tbl_filter(exists, dirs)
end

--- Resolve a theme name to a file.
---
--- Deliberately strict: filename match, then a case-insensitive match, and
--- nothing more. It is tempting to also ignore spaces and underscores so that
--- `Melange_dark` finds `Melange Dark`, but Ghostty itself does not do that — it
--- ignores the unresolvable name and falls back to its defaults. Matching more
--- loosely than the terminal means Neovim renders a theme the terminal isn't
--- using, which is precisely the mismatch this module exists to prevent.
local function find_theme_file(name)
  local want = name:lower()
  for _, dir in ipairs(theme_dirs()) do
    -- Try the literal filename first; it's the common case and avoids a dir scan.
    if exists(dir .. '/' .. name) then
      return dir .. '/' .. name
    end
    local fd = vim.uv.fs_scandir(dir)
    while fd do
      local entry = vim.uv.fs_scandir_next(fd)
      if not entry then
        break
      end
      if entry:lower() == want then
        return dir .. '/' .. entry
      end
    end
  end
end

---------------------------------------------------------------------------
-- Parsing
---------------------------------------------------------------------------

--- Read `key = value` lines out of a Ghostty config or theme file. Palette entries
--- (`palette = 0=#34302c`) are collected into `out.palette[0..15]`.
local function parse_into(path, out)
  local fd = io.open(path, 'r')
  if not fd then
    return out
  end
  for line in fd:lines() do
    line = line:gsub('^%s+', ''):gsub('%s+$', '')
    if line ~= '' and not line:match '^#' then
      local key, value = line:match '^([%w%-]+)%s*=%s*(.*)$'
      if key then
        key = key:lower()
        if key == 'palette' then
          local index, colour = value:match '^(%d+)%s*=%s*(#?%x+)$'
          if index then
            out.palette[tonumber(index)] = '#' .. colour:gsub('#', '')
          end
        elseif value ~= '' then
          out[key] = value
        end
      end
    end
  end
  fd:close()
  return out
end

--- macOS reports dark mode via this default; absent means light.
local function system_is_dark()
  local ok, result = pcall(vim.fn.system, 'defaults read -g AppleInterfaceStyle 2>/dev/null')
  return ok and result:match 'Dark' ~= nil
end

--- Ghostty allows `theme = dark:Foo,light:Bar`. Pick the side matching the OS.
local function resolve_theme_name(raw)
  if not raw:match '[dl][ai][rg][kh]t?:' then
    return raw
  end
  local dark, light = raw:match 'dark:([^,]+)', raw:match 'light:([^,]+)'
  local picked = system_is_dark() and dark or light
  return vim.trim(picked or dark or light or raw)
end

--- Ghostty's compiled-in defaults, used when no theme is set (or when the
--- configured one can't be resolved — same thing Ghostty does).
---
--- Asking the binary rather than hardcoding the values keeps this correct across
--- Ghostty upgrades. It costs ~13ms, which is why it's only reached when there's
--- no theme to read instead.
local defaults_cache
local function ghostty_defaults()
  -- Memoised: these can only change by upgrading Ghostty, and resolve() runs on
  -- every focus event.
  -- Copied on the way out: resolve() layers user overrides onto whatever it gets
  -- back, and mutating the cache would let a since-removed override linger.
  if defaults_cache ~= nil then
    return defaults_cache and vim.deepcopy(defaults_cache) or nil
  end
  local out = vim.system({ 'ghostty', '+show-config', '--default' }, { text = true }):wait()
  if out.code ~= 0 or not out.stdout then
    defaults_cache = false
    return nil
  end
  local colors = { palette = {} }
  local tmp = vim.fn.tempname()
  local fd = io.open(tmp, 'w')
  if not fd then
    defaults_cache = false
    return nil
  end
  fd:write(out.stdout)
  fd:close()
  parse_into(tmp, colors)
  os.remove(tmp)
  colors.name = 'Ghostty default'
  colors.source = 'ghostty +show-config --default'
  defaults_cache = colors
  return vim.deepcopy(colors)
end

--- Resolve the full colour set: theme file first, then the user's own config on
--- top (explicit `background`/`palette` lines in config override the theme).
function M.resolve()
  local config = M.config_path()
  if not config then
    return nil, 'no Ghostty config found'
  end

  local user = parse_into(config, { palette = {} })
  local colors

  if user.theme then
    local name = resolve_theme_name(user.theme)
    local file = find_theme_file(name)
    if file then
      colors = parse_into(file, { palette = {} })
      colors.name = name
      colors.source = file
    else
      -- Ghostty ignores a name it can't resolve and renders with its defaults,
      -- so we do too rather than guessing at what was meant.
      vim.notify(('Ghostty theme %q not found — Ghostty is using its defaults, matching it'):format(name), vim.log.levels.WARN)
    end
  end

  colors = colors or ghostty_defaults() or { palette = {} }

  -- User config wins over the theme file.
  for key, value in pairs(user) do
    if key ~= 'palette' and key ~= 'theme' then
      colors[key] = value
    end
  end
  for index, value in pairs(user.palette) do
    colors.palette[index] = value
  end

  if not colors.background or not colors.foreground or vim.tbl_count(colors.palette) < 16 then
    return nil, 'Ghostty theme is missing background, foreground, or a full 16-colour palette'
  end

  colors.background = '#' .. colors.background:gsub('#', '')
  colors.foreground = '#' .. colors.foreground:gsub('#', '')
  return colors
end

---------------------------------------------------------------------------
-- ANSI 16 -> base16
---------------------------------------------------------------------------

function M.to_base16(colors)
  local bg, fg = colors.background, colors.foreground
  local pal = colors.palette
  local dark = luminance(bg) < 0.5

  -- On a dark background the bright ANSI colours (8-15) read better; on a light
  -- one the normal colours (0-7) hold more contrast against the page.
  local function accent(n)
    return dark and pal[n + 8] or pal[n]
  end

  -- Greys are derived by walking from background toward foreground, which works
  -- in either direction and so handles light themes without a special case.
  return {
    base00 = bg, -- default background
    base01 = blend(bg, fg, 0.07), -- cursorline, statusline
    base02 = blend(bg, fg, 0.16), -- visual selection
    base03 = pal[8] or blend(bg, fg, 0.42), -- comments
    base04 = blend(bg, fg, 0.65), -- line numbers
    base05 = fg, -- default foreground
    base06 = blend(fg, pal[15], 0.5),
    base07 = pal[15],
    base08 = accent(1), -- red:     variables, errors
    base09 = blend(accent(1), accent(3), 0.5), -- orange:  numbers, constants (no ANSI slot)
    base0A = accent(3), -- yellow:  classes, search
    base0B = accent(2), -- green:   strings, added
    base0C = accent(6), -- cyan:    escapes, support
    base0D = accent(4), -- blue:    functions
    base0E = accent(5), -- magenta: keywords
    base0F = blend(accent(1), accent(5), 0.5), -- deprecated
  }
end

---------------------------------------------------------------------------
-- Applying
---------------------------------------------------------------------------

--- mini.base16 gives DiffAdd, DiffChange, DiffText, DiffDelete and Folded the
--- *same* background, which makes a review diff unreadable: added, removed and
--- changed lines are indistinguishable, and folds look like more of the same.
---
--- These are rebuilt from the theme's own green/red/blue so they still track
--- whatever Ghostty is set to. Crucially they set background only -- leaving `fg`
--- unset lets syntax highlighting show through the tint instead of the whole line
--- flattening to one colour.
local function refine_diff(p)
  local bg = p.base00
  local green, red, blue = p.base0B, p.base08, p.base0D

  local function hl(group, opts)
    vim.api.nvim_set_hl(0, group, opts)
  end

  hl('DiffAdd', { bg = blend(bg, green, 0.18) })
  hl('DiffChange', { bg = blend(bg, blue, 0.10) })
  -- The actual changed span within a line: this is the thing the eye should land
  -- on, so it gets roughly triple the tint of the line around it.
  hl('DiffText', { bg = blend(bg, blue, 0.34), bold = true })
  -- Deleted lines carry no syntax worth preserving, so a dimmed fg is fine here
  -- and keeps removals from shouting louder than the change itself.
  hl('DiffDelete', { bg = blend(bg, red, 0.13), fg = blend(bg, red, 0.55) })

  -- Folds sit between diff hunks; they should recede, not compete.
  hl('Folded', { bg = blend(bg, p.base05, 0.04), fg = p.base03, italic = true })
  hl('FoldColumn', { bg = bg, fg = p.base02 })
end

local last_applied

--- Build and apply the colorscheme. Returns true when it changed anything.
--- `opts.silent` suppresses the error notification (used by the file watcher).
function M.apply(opts)
  opts = opts or {}

  local colors, err = M.resolve()
  if not colors then
    if not opts.silent then
      vim.notify('Ghostty theme: ' .. err .. ' — falling back to habamax', vim.log.levels.WARN)
    end
    pcall(vim.cmd.colorscheme, 'habamax')
    return false
  end

  local base16 = M.to_base16(colors)

  -- Nothing to do if the palette is byte-for-byte what we already applied.
  local fingerprint = vim.inspect(base16)
  if not opts.force and fingerprint == last_applied then
    return false
  end
  last_applied = fingerprint

  vim.o.background = luminance(colors.background) < 0.5 and 'dark' or 'light'

  local ok, mini = pcall(require, 'mini.base16')
  if not ok then
    vim.notify('Ghostty theme: mini.base16 is not installed', vim.log.levels.ERROR)
    return false
  end
  mini.setup { palette = base16, use_cterm = false }
  refine_diff(base16)

  -- Override :terminal colours with the real Ghostty palette rather than the
  -- base16 approximation, so embedded terminals (including Claude Code) render
  -- byte-identically to a normal Ghostty pane.
  for i = 0, 15 do
    vim.g['terminal_color_' .. i] = colors.palette[i]
  end

  M.current = { name = colors.name or '(inline)', source = colors.source, palette = base16, ghostty = colors }
  vim.api.nvim_exec_autocmds('User', { pattern = 'GhosttyThemeChanged' })
  return true
end

---------------------------------------------------------------------------
-- Live reload
---------------------------------------------------------------------------

local watcher

local function watch()
  local config = M.config_path()
  if not config or watcher then
    return
  end

  -- Watch the containing directory, not the file: editors that write via
  -- rename-into-place swap the inode and a file watch would go deaf.
  local dir = vim.fs.dirname(config)
  local basename = vim.fs.basename(config)

  watcher = vim.uv.new_fs_event()
  watcher:start(
    dir,
    {},
    vim.schedule_wrap(function(err, filename)
      if err or (filename and filename ~= basename) then
        return
      end
      -- Debounce: editors often emit several events for one save.
      vim.defer_fn(function()
        M.apply { silent = true }
      end, 60)
    end)
  )
end

function M.setup()
  M.apply { force = true }
  watch()

  -- Catches theme changes made while Neovim was in the background, and the
  -- dark:/light: split following the OS appearance.
  vim.api.nvim_create_autocmd('FocusGained', {
    group = vim.api.nvim_create_augroup('ghostty_theme', { clear = true }),
    callback = function()
      M.apply { silent = true }
    end,
  })

  vim.api.nvim_create_user_command('GhosttyTheme', function()
    local changed = M.apply { force = true }
    vim.notify(('Ghostty theme: %s%s'):format(M.current and M.current.name or 'unknown', changed and ' (reloaded)' or ''))
  end, { desc = 'Reload the colorscheme from the current Ghostty theme' })

  vim.api.nvim_create_user_command('GhosttyThemeInfo', function()
    if not M.current then
      vim.notify('No Ghostty theme resolved', vim.log.levels.WARN)
      return
    end
    local lines = {
      'theme:  ' .. M.current.name,
      'file:   ' .. (M.current.source or '(from config)'),
      'config: ' .. (M.config_path() or '?'),
      'background: ' .. vim.o.background,
      '',
    }
    local keys = vim.tbl_keys(M.current.palette)
    table.sort(keys)
    for _, key in ipairs(keys) do
      table.insert(lines, ('%s = %s'):format(key, M.current.palette[key]))
    end
    vim.notify(table.concat(lines, '\n'))
  end, { desc = 'Show the resolved Ghostty theme and generated palette' })
end

return M
