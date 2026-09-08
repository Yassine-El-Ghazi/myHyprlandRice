-- -----------------------------------------------------
-- Environment Variables
-- name: "Nvidia"
-- -----------------------------------------------------

-- Default settings in myhypr.conf

-- Dedicated NVIDIA compatibility profile. Hybrid/offload systems should use
-- the default profile and put proven host-specific exceptions in local.lua.
hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")

hl.config({
    cursor = {
        no_hardware_cursors = true,
    },
})
