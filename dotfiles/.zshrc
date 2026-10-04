#            _
#    _______| |__  _ __ ___
#   |_  / __| '_ \| '__/ __|
#  _ / /\__ \ | | | | | (__
# (_)___|___/_| |_|_|  \___|
#
# -----------------------------------------------------
# MyHyprlandRice zshrc loader
# -----------------------------------------------------

# You can override a modular file by placing a file with the same name in
# ~/.config/zshrc/custom, or keep machine-only settings in ~/.zshrc_custom.
# -----------------------------------------------------

# -----------------------------------------------------
# Load modular configuration
# -----------------------------------------------------
# Keep trusted system command directories ahead of user-writable directories.
# 00-init normalizes module paths; the loader restores precedence at the end.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:$HOME/.config/myhypr/bin:$HOME/.local/bin:$PATH"

for config_file in "$HOME"/.config/zshrc/*(N); do
    # Stow may link each module individually. Test the resolved target instead
    # of using the `.` glob qualifier, which silently excludes symlinks.
    [[ -f "$config_file" && -r "$config_file" ]] || continue
    override_file="$HOME/.config/zshrc/custom/${config_file:t}"
    if [[ -f "$override_file" ]]; then
        source "$override_file"
    else
        source "$config_file"
    fi
done
unset config_file override_file

# -----------------------------------------------------
# Load single customization file (if exists)
# -----------------------------------------------------

if [[ -r "$HOME/.zshrc_custom" ]]; then
    source "$HOME/.zshrc_custom"
fi

# Unity CLI
case ":${PATH}:" in *:"$HOME/.local/bin":*) ;; *) path+=("$HOME/.local/bin") ;; esac

# Android SDK
export ANDROID_HOME="$HOME/Android/Sdk"

for sdk_bin in "$ANDROID_HOME"/{platform-tools,emulator,cmdline-tools/latest/bin}; do
    [[ ! -d "$sdk_bin" ]] || path+=("$sdk_bin")
done
unset sdk_bin

typeset -U path PATH
# Custom modules and tool integrations may prepend paths. Restore the policy
# after every loader addition, retaining the tools after trusted commands.
path=(/usr/local/sbin /usr/local/bin /usr/bin /bin /usr/sbin "${path[@]}")
