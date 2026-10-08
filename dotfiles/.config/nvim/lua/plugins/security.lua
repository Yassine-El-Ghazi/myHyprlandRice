-- Override core plugins; no additional plugin is installed.
return {
  {
    'neovim/nvim-lspconfig',
    opts = {
      servers = {
        lua_ls = { cmd = require('config.luals').cmd },
      },
    },
  },
  { 'folke/persistence.nvim', enabled = false },
}
