-- Server-side overrides take precedence over workspace and client settings.
-- Validate before spawning: LuaLS interprets non-JSON config files as Lua.
local M = {}

function M.cmd(dispatchers, config)
  local policy = vim.fn.stdpath('config') .. '/luals-safe.json'
  local file = io.open(policy, 'rb')
  if not file then
    error('LuaLS refused to start: safety policy is missing')
  end
  local contents = file:read(16385)
  file:close()
  if not contents or #contents > 16384 or not contents:match('^%s*{') then
    error('LuaLS refused to start: safety policy is invalid')
  end
  local ok, settings = pcall(vim.json.decode, contents)
  local expected = {
    ['runtime.plugin'] = true,
    ['runtime.pluginArgs'] = true,
    ['workspace.userThirdParty'] = true,
    ['workspace.checkThirdParty'] = 'Disable',
    docScriptPath = '',
  }
  if not ok or type(settings) ~= 'table' then
    error('LuaLS refused to start: safety policy is invalid')
  end
  for key, value in pairs(expected) do
    if value == true then
      if type(settings[key]) ~= 'table' or next(settings[key]) ~= nil then
        error('LuaLS refused to start: safety policy is invalid')
      end
    elseif settings[key] ~= value then
      error('LuaLS refused to start: safety policy is invalid')
    end
  end
  for key in pairs(settings) do
    if expected[key] == nil then
      error('LuaLS refused to start: safety policy is invalid')
    end
  end
  local env = vim.tbl_extend('force', config.cmd_env or {}, { LLS_CONFIG_PATH = policy })
  return vim.lsp.rpc.start({ 'lua-language-server', '--configpath=' .. policy }, dispatchers, {
    cwd = config.cmd_cwd,
    detached = config.detached,
    env = env,
  })
end

return M
