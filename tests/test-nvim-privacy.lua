-- Use only synthetic files and an in-memory clipboard; no plugins or services.
local repo = assert(arg[1])
local config = repo .. '/dotfiles/.config/nvim/'
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, 'p', '0700')
local copied = {}
local function copy(lines) copied[#copied + 1] = table.concat(lines, '\n') end
vim.g.clipboard = {
  name = 'synthetic-only',
  copy = { ['+'] = copy, ['*'] = copy },
  paste = { ['+'] = function() return { {}, 'v' } end, ['*'] = function() return { {}, 'v' } end },
  cache_enabled = 0,
}
local ok, failure = pcall(function()
  -- Model upstream defaults that local options must override.
  vim.opt.clipboard = 'unnamedplus'
  vim.opt.undofile = true
  vim.opt.swapfile = true
  vim.opt.undodir = directory .. '/undo'
  vim.opt.directory = directory .. '/swap'
  vim.fn.mkdir(directory .. '/undo', 'p', '0700')
  vim.fn.mkdir(directory .. '/swap', 'p', '0700')
  package.preload['config.lazy'] = function()
    assert(vim.o.shadafile == 'NONE', 'ShaDa is not disabled before bootstrap')
    return {}
  end
  dofile(config .. 'init.lua')
  dofile(config .. 'lua/config/options.lua')
  assert(vim.o.clipboard == '', 'unnamed registers publish clipboard text')
  assert(not vim.o.undofile and not vim.o.swapfile, 'disk-backed buffer state enabled')
  assert(vim.o.shadafile == 'NONE' and vim.o.shada == '', 'ShaDa persistence enabled')
  local file = directory .. '/.env'
  vim.fn.writefile({ 'synthetic-prior-value', 'synthetic-current-value' }, file)
  vim.fn.setfperm(file, 'rw-------')
  vim.cmd.edit(file)
  vim.cmd('normal! dd')
  assert(#copied == 0, 'ordinary deletion published synthetic text')
  vim.cmd.write()
  assert(vim.fn.filereadable(vim.fn.undofile(file)) == 0, 'deleted text retained in an undo file')
  assert(#vim.fn.glob(directory .. '/swap/*', false, true) == 0, 'swap file created')
  vim.cmd('normal! u')
  assert(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == 'synthetic-prior-value', 'in-memory undo stopped working')
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd('normal! "+yy')
  assert(copied[#copied] == 'synthetic-prior-value\n', 'explicit clipboard copy stopped working')
  package.path = config .. 'lua/?.lua;' .. package.path
  local disabled = false
  for _, spec in ipairs(dofile(config .. 'lua/plugins/security.lua')) do
    if spec[1] == 'folke/persistence.nvim' then disabled = spec.enabled == false end
  end
  assert(disabled, 'automatic sessions still retain buffer paths')
end)
vim.cmd('silent! bwipeout!')
vim.fn.delete(directory, 'rf')
assert(ok, failure)
print('Private editing keeps ordinary registers local and avoids disk-backed editor state; explicit copying and in-memory undo work.')
