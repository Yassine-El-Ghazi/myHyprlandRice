-- Exercise bootstrap paths without downloading or executing any plugin.
local repo = assert(arg[1])
local root = repo .. '/dotfiles/.config/nvim/'
local original_stdpath, original_system, original_stat, original_delete = vim.fn.stdpath, vim.fn.system, vim.uv.fs_stat, vim.fn.delete
local options, commands, deleted
package.preload.lazy = function()
  return { setup = function(value) options = value end }
end
local function run(exists, failure)
  options, commands, deleted = nil, {}, false
  vim.fn.stdpath = function(kind)
    assert(kind == 'data')
    return '/fixture/data'
  end
  vim.uv.fs_stat = function() return exists and {} or nil end
  vim.fn.system = function(command)
    commands[#commands + 1] = command
    original_system { failure and '/bin/false' or '/bin/true' }
    return 'synthetic Git result'
  end
  vim.fn.delete = function(path, flag)
    assert(path == '/fixture/data/lazy/lazy.nvim' and flag == 'rf')
    deleted = true
  end
  return pcall(dofile, root .. 'lua/config/lazy.lua')
end
local ok, failure = pcall(function()
  assert(run(true, false))
  assert(#commands == 0, 'existing manager was reinstalled')
  assert(options.spec[1][1] == 'LazyVim/LazyVim' and options.spec[1].import == 'lazyvim.plugins')
  assert(options.spec[1].version == '*' and not options.spec[1].commit and not options.spec[1].pin)
  assert(options.local_spec == false, 'project plugin specs enabled')
  assert(options.checker.enabled and options.checker.notify, 'update notifications disabled')
  assert(run(false, false))
  assert(#commands == 1 and commands[1][1] == 'git' and commands[1][2] == 'clone')
  assert(vim.tbl_contains(commands[1], '--branch=stable'), 'bootstrap does not follow stable releases')
  assert(not run(false, true), 'failed clone accepted')
  assert(deleted and not options, 'failed bootstrap left state or loaded plugins')
end)
vim.fn.stdpath, vim.fn.system, vim.uv.fs_stat, vim.fn.delete = original_stdpath, original_system, original_stat, original_delete
assert(ok, failure)

dofile(root .. 'lua/config/options.lua')
assert(not vim.o.exrc and not vim.o.modeline)
package.path = root .. 'lua/?.lua;' .. package.path
local specs = dofile(root .. 'lua/plugins/security.lua')
assert(specs[1].opts.servers.lua_ls.cmd == require('config.luals').cmd, 'LuaLS guard is not connected')
local file = assert(io.open(root .. 'lazy-lock.json'))
local lock = vim.json.decode(file:read('*a'))
file:close()
assert(lock.LazyVim and lock['lazy.nvim'])
for name, value in pairs(lock) do
  assert(not name:lower():find('copilot', 1, true), 'old AI plugin remains locked')
  assert(value.commit:match('^[0-9a-f]+$') and #value.commit == 40, 'invalid lock entry')
end
print('LazyVim bootstrap fails safely, follows stable updates, and preserves project-code guards.')
