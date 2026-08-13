-- The colorscheme is generated at runtime from whatever theme Ghostty is using.
-- See lua/ghostty/theme.lua for how the ANSI palette becomes a base16 palette.
return {
  {
    'echasnovski/mini.base16',
    version = false,
    lazy = false,
    priority = 1000, -- must load before anything that defines highlights
    config = function()
      require('ghostty.theme').setup()
    end,
  },
}
