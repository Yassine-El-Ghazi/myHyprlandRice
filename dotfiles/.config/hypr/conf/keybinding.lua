-- Keybinding variants are Lua-only. The mutable selector stores one bounded
-- profile name so changing layouts never evaluates generated code or paths.
local profile = "default"
local allowed = { default = true, fr = true }
local home = os.getenv("HOME")

if home then
    local selector = io.open(home .. "/.config/myhypr/settings/keybinding-profile", "r")
    if selector then
        local selected = selector:read("*all")
        selector:close()
        selected = selected:match("^([a-z]+)%s*$")
        if selected and allowed[selected] then
            profile = selected
        end
    end
end

require("conf.keybindings." .. profile)
