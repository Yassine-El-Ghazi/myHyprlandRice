local gamemode = {}

function gamemode.apply()
    hl.config({
        animations = { enabled = false },
        decoration = {
            shadow = { enabled = false },
            blur = { enabled = false },
            active_opacity = 1,
            inactive_opacity = 1,
            fullscreen_opacity = 1,
            rounding = 0,
        },
        general = {
            gaps_in = 0,
            gaps_out = 0,
            border_size = 1,
        },
    })
    return true
end

function gamemode.apply_persisted()
    local home = os.getenv("HOME")
    if not home then
        return false
    end

    local marker = io.open(home .. "/.config/myhypr/settings/gamemode-enabled", "r")
    if not marker then
        return false
    end
    marker:close()
    return gamemode.apply()
end

return gamemode
