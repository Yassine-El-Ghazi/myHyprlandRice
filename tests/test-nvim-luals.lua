-- Run in bare Neovim; no plugins, server, or project code are loaded.
local repo = assert(arg[1], 'repository root required')
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, 'p', 448)
local original_stdpath = vim.fn.stdpath
local original_start = vim.lsp.rpc.start
local calls = 0
local command, options
vim.fn.stdpath = function(kind)
  assert(kind == 'config')
  return directory
end
vim.lsp.rpc.start = function(cmd, _, opts)
  calls = calls + 1
  command, options = cmd, opts
  return 'fixture-rpc'
end
local policy = directory .. '/luals-safe.json'
local module = dofile(repo .. '/dotfiles/.config/nvim/lua/config/luals.lua')
local function write(contents)
  local file = assert(io.open(policy, 'wb'))
  file:write(contents)
  file:close()
end
local function refused(contents)
  if contents then
    write(contents)
  else
    vim.fn.delete(policy)
  end
  local before = calls
  assert(not pcall(module.cmd, {}, { cmd_env = {} }), 'unsafe policy was accepted')
  assert(calls == before, 'RPC started before policy validation')
end
local ok, failure = pcall(function()
  refused(nil)
  refused('unrecognized policy')
  refused('{ invalid json')
  refused('{}')
  refused(string.rep(' ', 16385))
  local source = assert(io.open(repo .. '/dotfiles/.config/nvim/luals-safe.json', 'rb'))
  local trusted = source:read('*a')
  source:close()
  local values = vim.json.decode(trusted)
  for key, replacement in pairs {
    ['runtime.plugin'] = { 'untrusted-plugin' },
    ['runtime.pluginArgs'] = { 'untrusted-argument' },
    ['workspace.userThirdParty'] = { 'untrusted-addon' },
    ['workspace.checkThirdParty'] = 'Ask',
    docScriptPath = 'untrusted-doc-script',
  } do
    local changed = vim.deepcopy(values)
    changed[key] = replacement
    refused(vim.json.encode(changed))
  end
  values.unexpected = true
  refused(vim.json.encode(values))
  write(trusted)
  assert(module.cmd({}, { cmd_env = { LLS_CONFIG_PATH = 'untrusted', EXTRA = 'retained' } }) == 'fixture-rpc')
  assert(calls == 1)
  assert(command[1] == 'lua-language-server' and command[2] == '--configpath=' .. policy)
  assert(options.env.LLS_CONFIG_PATH == policy and options.env.EXTRA == 'retained')
end)
vim.fn.stdpath = original_stdpath
vim.lsp.rpc.start = original_start
vim.fn.delete(directory, 'rf')
assert(ok, failure)
print('LuaLS startup validates and enforces trusted execution restrictions.')
