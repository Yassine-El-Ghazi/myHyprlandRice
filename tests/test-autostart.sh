#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
AUTOSTART="$REPO_ROOT/dotfiles/.config/hypr/conf/autostart.lua"

lua - "$AUTOSTART" <<'LUA'
local autostart = arg[1]
local commands = {}

hl = {
    exec_cmd = function(command)
        table.insert(commands, command)
    end,
    on = function(event, callback)
        assert(event == "hyprland.start", "unexpected lifecycle event: " .. event)
        callback()
    end,
}

dofile(autostart)

local managed_dock = "~/.config/nwg-dock-hyprland/launch.sh"
for _, command in ipairs(commands) do
    if command == managed_dock then
        print("Hyprland starts the dock through its managed launcher.")
        os.exit(0)
    end
end

io.stderr:write("Hyprland bypasses the managed dock launcher.\n")
os.exit(1)
LUA
