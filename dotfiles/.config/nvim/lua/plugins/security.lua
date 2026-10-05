-- Override an existing core plugin; no additional plugin is installed.
return {
  {
    'neovim/nvim-lspconfig',
    opts = {
      servers = {
        lua_ls = { cmd = require('config.luals').cmd },
      },
    },
  },
}
