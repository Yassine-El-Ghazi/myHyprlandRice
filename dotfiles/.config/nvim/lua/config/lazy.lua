local lazypath = vim.fn.stdpath('data') .. '/lazy/lazy.nvim'
if not vim.uv.fs_stat(lazypath) then
  local output = vim.fn.system {
    'git', 'clone', '--filter=blob:none', '--branch=stable',
    'https://github.com/folke/lazy.nvim.git', lazypath,
  }
  if vim.v.shell_error ~= 0 then
    vim.fn.delete(lazypath, 'rf')
    error('Could not install stable lazy.nvim:\n' .. output)
  end
end
vim.opt.rtp:prepend(lazypath)

require('lazy').setup {
  spec = {
    { 'LazyVim/LazyVim', import = 'lazyvim.plugins', version = '*' },
    { import = 'plugins' },
  },
  local_spec = false,
  defaults = { lazy = false, version = false },
  install = { colorscheme = { 'tokyonight', 'habamax' } },
  checker = { enabled = true, notify = true },
  change_detection = { notify = false },
  performance = {
    rtp = { disabled_plugins = { 'gzip', 'tarPlugin', 'tohtml', 'tutor', 'zipPlugin' } },
  },
}
