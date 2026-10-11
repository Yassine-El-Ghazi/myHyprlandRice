local lazypath = vim.fn.stdpath('data') .. '/lazy/lazy.nvim'
-- Adopt bootstrap revisions deliberately, together with lazy-lock.json.
local bootstrap_commit = '85c7ff3711b730b4030d03144f6db6375044ae82'
if not vim.uv.fs_stat(lazypath) then
  local commands = {
    { 'git', 'clone', '--filter=blob:none', '--no-checkout',
      'https://github.com/folke/lazy.nvim.git', lazypath },
    { 'git', '-C', lazypath, 'checkout', '--detach', bootstrap_commit },
    { 'git', '-C', lazypath, 'rev-parse', 'HEAD' },
  }
  for index, command in ipairs(commands) do
    local output = vim.fn.system(command)
    if vim.v.shell_error ~= 0 or (index == 3 and vim.trim(output) ~= bootstrap_commit) then
      vim.fn.delete(lazypath, 'rf')
      error('Could not install the pinned lazy.nvim bootstrap revision')
    end
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
