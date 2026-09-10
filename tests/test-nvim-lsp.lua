local root = assert(arg[1], "repository root is required")
local path = root .. "/dotfiles/.config/nvim/init.lua"
local file = assert(io.open(path, "r"))
local config = file:read("*all")
file:close()

assert(not config:find("automatic_installation", 1, true), "removed automatic_installation option remains")
assert(not config:find("handlers =", 1, true), "removed Mason handlers option remains")
assert(config:find("vim.lsp.config(server_name, server)", 1, true), "servers do not use Neovim's native LSP API")
assert(config:find("automatic_enable = server_names", 1, true), "configured servers are not enabled through Mason v2")
assert(config:find("server.capabilities = vim.tbl_deep_extend", 1, true), "completion capabilities are not applied")

print("Neovim LSP configuration uses the supported Mason v2 API.")
