local source = debug.getinfo(1, "S").source:sub(2)
if source:sub(1, 1) ~= "/" then
    source = assert(os.getenv("PWD"), "PWD is unavailable") .. "/" .. source
end
local repo_root = assert(source:match("^(.*)/tests/test%-keybindings%.lua$"))
local expected_counts = { default = 111, fr = 107 }
local required = {
    default = { "SUPER + SHIFT + T", "SUPER + SHIFT + A", "SUPER + ALT + G", "CTRL + Tab", "SUPER + CTRL + 0", "XF86AudioRaiseVolume" },
    fr = { "SUPER + SHIFT + T", "SUPER + SHIFT + A", "SUPER + ALT + G", "CTRL + Tab", "SUPER + CTRL + agrave", "XF86AudioRaiseVolume" },
}
local approved_external = {
    brightnessctl = true, hyprctl = true, hyprlock = true, hyprshot = true,
    pactl = true, playerctl = true, wpctl = true,
}

local doctor_file = assert(io.open(repo_root .. "/scripts/doctor.sh", "r"))
local doctor_source = doctor_file:read("*a")
doctor_file:close()

local function namespace(prefix)
    return setmetatable({}, {
        __index = function(table_value, name)
            local factory = function(...)
                return { kind = prefix .. name, args = { ... } }
            end
            rawset(table_value, name, factory)
            return factory
        end,
    })
end

local runtime_actions = {
    toggle_all_float = function() return { ok = true } end,
}

local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function load_variant(name)
    local bindings = {}
    local dsp = namespace("hl.dsp.")
    dsp.window = namespace("hl.dsp.window.")
    dsp.group = namespace("hl.dsp.group.")
    dsp.cursor = namespace("hl.dsp.cursor.")
    dsp.workspace = namespace("hl.dsp.workspace.")
    local mock_hl = {
        dsp = dsp,
        bind = function(key, action)
            assert(type(key) == "string" and action ~= nil)
            bindings[#bindings + 1] = { key = key, action = action }
        end,
    }
    local environment = setmetatable({
        hl = mock_hl,
        require = function(module)
            assert(module == "conf.runtime_actions")
            return runtime_actions
        end,
    }, { __index = _G })
    local path = repo_root .. "/dotfiles/.config/hypr/conf/keybindings/" .. name .. ".lua"
    assert(loadfile(path, "t", environment))()
    return bindings
end

for _, name in ipairs({ "default", "fr" }) do
    local bindings = load_variant(name)
    assert(#bindings == expected_counts[name], name .. " binding count changed")
    local keys = {}
    local direct_all_float = false
    for _, binding in ipairs(bindings) do
        keys[binding.key] = true
        if binding.key == "SUPER + SHIFT + T" then
            direct_all_float = binding.action == runtime_actions.toggle_all_float
        end
        if type(binding.action) == "table" and binding.action.kind == "hl.dsp.exec_cmd" then
            local command = assert(binding.action.args[1])
            local executable = assert(command:match("^([^%s]+)"))
            if executable:sub(1, 10) == "~/.config/" then
                local managed = repo_root .. "/dotfiles" .. executable:sub(2)
                local file = assert(io.open(managed, "r"), "missing managed command: " .. managed)
                file:close()
                assert(os.execute("test -x " .. shell_quote(managed)), "managed command is not executable: " .. managed)
            else
                assert(approved_external[executable], "unapproved external command: " .. executable)
                assert(doctor_source:find(executable, 1, true), "doctor does not check: " .. executable)
            end
        end
    end
    for _, key in ipairs(required[name]) do
        assert(keys[key], name .. " lost required key " .. key)
    end
    assert(direct_all_float, name .. " all-float bind still spawns a shell helper")
end

print("Both keybinding variants preserve counts and resolve every command.")
