local M = {}
local enabled = {}
local subscriptions = {}
local MODE_TAG = "myhypr-allfloat-mode"
local CONVERTED_TAG = "myhypr-allfloat-converted"

local function has_tag(window, wanted)
    for _, tag in ipairs(window.tags or {}) do
        if tag == wanted then return true end
    end
    return false
end

local function dispatch_or_error(action)
    local result = hl.dispatch(action)
    if type(result) ~= "table" or result.ok ~= true then
        local message = type(result) == "table" and result.error or nil
        error(message or "Hyprland rejected an all-float action", 0)
    end
end

local function add_tag(window, tag)
    if not has_tag(window, tag) then
        dispatch_or_error(hl.dsp.window.tag({ tag = "+" .. tag, window = window }))
    end
end

local function remove_tag(window, tag)
    if has_tag(window, tag) then
        dispatch_or_error(hl.dsp.window.tag({ tag = "-" .. tag, window = window }))
    end
end

local function enable_window(window)
    if not window.mapped or not window.visible then return end
    if not window.floating then
        -- Record provenance before changing layout so a later failure cannot lose it.
        add_tag(window, CONVERTED_TAG)
        dispatch_or_error(hl.dsp.window.float({ action = "enable", window = window }))
    end
    add_tag(window, MODE_TAG)
end

local function disable_window(window)
    if has_tag(window, CONVERTED_TAG) then
        dispatch_or_error(hl.dsp.window.float({ action = "disable", window = window }))
        remove_tag(window, CONVERTED_TAG)
    end
    remove_tag(window, MODE_TAG)
end

local function notify_failure()
    hl.exec_cmd("notify-send -u critical 'All-float action failed' 'Hyprland rejected the workspace transition'")
end

for _, window in ipairs(hl.get_windows()) do
    if window.workspace and has_tag(window, MODE_TAG) then
        enabled[window.workspace.id] = true
    end
end

function M.toggle_all_float()
    local workspace = hl.get_active_workspace()
    if not workspace then
        notify_failure()
        return { ok = false, error = "No active workspace" }
    end

    local turn_on = not enabled[workspace.id]
    local ok, err = pcall(function()
        for _, window in ipairs(workspace:get_windows()) do
            if turn_on then enable_window(window) else disable_window(window) end
        end
    end)
    if not ok then
        notify_failure()
        return { ok = false, error = tostring(err) }
    end

    enabled[workspace.id] = turn_on or nil
    hl.exec_cmd("notify-send 'Windows on this workspace toggled to floating/tiling'")
    return { ok = true }
end

subscriptions[#subscriptions + 1] = hl.on("window.open", function(window)
    if window.workspace and enabled[window.workspace.id] then
        local ok = pcall(enable_window, window)
        if not ok then notify_failure() end
    end
end)

subscriptions[#subscriptions + 1] = hl.on("window.move_to_workspace", function(window, workspace)
    local ok = pcall(function()
        if workspace and enabled[workspace.id] then enable_window(window) else disable_window(window) end
    end)
    if not ok then notify_failure() end
end)

subscriptions[#subscriptions + 1] = hl.on("workspace.removed", function(workspace)
    if workspace and workspace.id then enabled[workspace.id] = nil end
end)

return M
