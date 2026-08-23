local source = debug.getinfo(1, "S").source:sub(2)
local repo_root = source:match("^(.*)/tests/test%-runtime%-actions%.lua$")
    or source:match("^tests/test%-runtime%-actions%.lua$") and "."
assert(repo_root)
package.path = repo_root .. "/dotfiles/.config/hypr/?.lua;" .. package.path

local callbacks = {}
local notifications = {}
local all_windows = {}
local active_workspace = nil
local forced_failure = nil
local MODE_TAG = "myhypr-allfloat-mode"
local CONVERTED_TAG = "myhypr-allfloat-converted"

local function tag_index(window, wanted)
    for index, tag in ipairs(window.tags or {}) do
        if tag == wanted then return index end
    end
    return nil
end

local function has_tag(window, wanted)
    return tag_index(window, wanted) ~= nil
end

local function dispatcher(kind, opts)
    return { kind = kind, opts = opts or {} }
end

hl = {
    dsp = {
        window = {
            float = function(opts) return dispatcher("float", opts) end,
            tag = function(opts) return dispatcher("tag", opts) end,
        },
    },
    dispatch = function(action)
        if forced_failure and forced_failure(action) then
            return { ok = false, error = "forced " .. action.kind .. " failure" }
        end
        local window = action.opts.window
        if action.kind == "float" then
            local float_action = action.opts.action
            if float_action == "enable" or float_action == "on" then
                window.floating = true
            elseif float_action == "disable" or float_action == "off" then
                window.floating = false
            else
                window.floating = not window.floating
            end
        elseif action.kind == "tag" then
            local prefix = action.opts.tag:sub(1, 1)
            local tag = action.opts.tag:sub(2)
            window.tags = window.tags or {}
            local index = tag_index(window, tag)
            if prefix == "+" and not index then
                table.insert(window.tags, tag)
            elseif prefix == "-" and index then
                table.remove(window.tags, index)
            end
        end
        return { ok = true }
    end,
    exec_cmd = function(command) notifications[#notifications + 1] = command end,
    get_active_workspace = function() return active_workspace end,
    get_windows = function() return all_windows end,
    on = function(name, callback) callbacks[name] = callback; return { name = name } end,
}

local function make_workspace(id, windows)
    local workspace = { id = id, windows = windows }
    function workspace:get_windows() return self.windows end
    for _, window in ipairs(windows) do
        window.workspace = workspace
        all_windows[#all_windows + 1] = window
    end
    return workspace
end

local function move_window(window, workspace)
    local previous = window.workspace
    if previous then
        for index, candidate in ipairs(previous.windows) do
            if candidate == window then
                table.remove(previous.windows, index)
                break
            end
        end
    end
    workspace.windows[#workspace.windows + 1] = window
    window.workspace = workspace
    callbacks["window.move_to_workspace"](window, workspace)
end

local function success_notifications()
    local count = 0
    for _, command in ipairs(notifications) do
        if command:find("Windows on this workspace toggled", 1, true) then count = count + 1 end
    end
    return count
end

local tiled = { mapped = true, visible = true, floating = false, tags = {} }
local intentional_float = { mapped = true, visible = true, floating = true, tags = {} }
local non_visible = { mapped = true, visible = false, floating = false, tags = {} }
local workspace_one = make_workspace(1, { tiled, intentional_float, non_visible })
active_workspace = workspace_one

package.loaded["conf.runtime_actions"] = nil
local runtime_actions = require("conf.runtime_actions")
local result = runtime_actions.toggle_all_float()
assert(result.ok)
assert(tiled.floating and has_tag(tiled, MODE_TAG) and has_tag(tiled, CONVERTED_TAG))
assert(intentional_float.floating and has_tag(intentional_float, MODE_TAG))
assert(not has_tag(intentional_float, CONVERTED_TAG))
assert(not non_visible.floating and not has_tag(non_visible, MODE_TAG) and not has_tag(non_visible, CONVERTED_TAG))

local opened = { mapped = true, visible = true, floating = false, tags = {}, workspace = workspace_one }
all_windows[#all_windows + 1] = opened
workspace_one.windows[#workspace_one.windows + 1] = opened
callbacks["window.open"](opened)
assert(opened.floating and has_tag(opened, MODE_TAG) and has_tag(opened, CONVERTED_TAG))

result = runtime_actions.toggle_all_float()
assert(result.ok)
assert(not tiled.floating and not has_tag(tiled, MODE_TAG) and not has_tag(tiled, CONVERTED_TAG))
assert(intentional_float.floating and not has_tag(intentional_float, MODE_TAG))
assert(not opened.floating and not has_tag(opened, MODE_TAG) and not has_tag(opened, CONVERTED_TAG))

assert(runtime_actions.toggle_all_float().ok)
local moved_in = { mapped = true, visible = true, floating = false, tags = {} }
local workspace_two = make_workspace(2, { moved_in })
move_window(moved_in, workspace_one)
assert(moved_in.floating and has_tag(moved_in, MODE_TAG) and has_tag(moved_in, CONVERTED_TAG))

move_window(intentional_float, workspace_two)
assert(intentional_float.floating and not has_tag(intentional_float, MODE_TAG))
assert(not has_tag(intentional_float, CONVERTED_TAG))

move_window(tiled, workspace_two)
assert(not tiled.floating and not has_tag(tiled, MODE_TAG) and not has_tag(tiled, CONVERTED_TAG))

package.loaded["conf.runtime_actions"] = nil
callbacks = {}
runtime_actions = require("conf.runtime_actions")
local after_reload = { mapped = true, visible = true, floating = false, tags = {}, workspace = workspace_one }
all_windows[#all_windows + 1] = after_reload
callbacks["window.open"](after_reload)
assert(after_reload.floating and has_tag(after_reload, MODE_TAG) and has_tag(after_reload, CONVERTED_TAG))

callbacks["workspace.removed"](workspace_one)
local after_removed = { mapped = true, visible = true, floating = false, tags = {}, workspace = workspace_one }
all_windows[#all_windows + 1] = after_removed
callbacks["window.open"](after_removed)
assert(not after_removed.floating and not has_tag(after_removed, MODE_TAG) and not has_tag(after_removed, CONVERTED_TAG))

local failing = { mapped = true, visible = true, floating = false, tags = {} }
local workspace_three = make_workspace(3, { failing })
active_workspace = workspace_three
local successes_before = success_notifications()
forced_failure = function(action) return action.kind == "float" end
result = runtime_actions.toggle_all_float()
forced_failure = nil
assert(result.ok == false)
assert(success_notifications() == successes_before)

local provenance = { mapped = true, visible = true, floating = false, tags = {} }
local workspace_four = make_workspace(4, { provenance })
active_workspace = workspace_four
successes_before = success_notifications()
forced_failure = function(action)
    return action.kind == "tag" and action.opts.tag == "+" .. CONVERTED_TAG
end
result = runtime_actions.toggle_all_float()
forced_failure = nil
assert(result.ok == false)
assert(not provenance.floating)
assert(not has_tag(provenance, CONVERTED_TAG))
assert(not has_tag(provenance, MODE_TAG))
assert(success_notifications() == successes_before)

local partial = { mapped = true, visible = true, floating = false, tags = {} }
local workspace_five = make_workspace(5, { partial })
active_workspace = workspace_five
successes_before = success_notifications()
forced_failure = function(action)
    return action.kind == "tag" and action.opts.tag == "+" .. MODE_TAG
end
result = runtime_actions.toggle_all_float()
forced_failure = nil
assert(result.ok == false)
assert(partial.floating)
assert(has_tag(partial, CONVERTED_TAG))
assert(not has_tag(partial, MODE_TAG))
assert(success_notifications() == successes_before)

assert(runtime_actions.toggle_all_float().ok)
assert(partial.floating and has_tag(partial, MODE_TAG) and has_tag(partial, CONVERTED_TAG))
assert(runtime_actions.toggle_all_float().ok)
assert(not partial.floating and not has_tag(partial, MODE_TAG) and not has_tag(partial, CONVERTED_TAG))

local disable_retry = { mapped = true, visible = true, floating = false, tags = {} }
local workspace_six = make_workspace(6, { disable_retry })
active_workspace = workspace_six
assert(runtime_actions.toggle_all_float().ok)
assert(disable_retry.floating and has_tag(disable_retry, MODE_TAG) and has_tag(disable_retry, CONVERTED_TAG))

successes_before = success_notifications()
forced_failure = function(action)
    return action.kind == "tag" and action.opts.tag == "-" .. CONVERTED_TAG
end
result = runtime_actions.toggle_all_float()
forced_failure = nil
assert(result.ok == false)
assert(not disable_retry.floating)
assert(has_tag(disable_retry, MODE_TAG) and has_tag(disable_retry, CONVERTED_TAG))
assert(success_notifications() == successes_before)

assert(runtime_actions.toggle_all_float().ok)
assert(not disable_retry.floating)
assert(not has_tag(disable_retry, MODE_TAG) and not has_tag(disable_retry, CONVERTED_TAG))

print("Stateful all-float preserves intentional windows and survives reload markers.")
