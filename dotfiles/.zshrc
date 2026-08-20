#            _
#    _______| |__  _ __ ___
#   |_  / __| '_ \| '__/ __|
#  _ / /\__ \ | | | | | (__
# (_)___|___/_| |_|_|  \___|
#
# -----------------------------------------------------
# ML4W zshrc loader
# -----------------------------------------------------

# You can override a modular file by placing a file with the same name in
# ~/.config/zshrc/custom, or keep machine-only settings in ~/.zshrc_custom.
# -----------------------------------------------------

# -----------------------------------------------------
# Load modular configuration
# -----------------------------------------------------
# Keep per-user commands available even if the modular directory is absent.
# 00-init normalizes and de-duplicates the final path when it is present.
export PATH="$HOME/.local/bin:$PATH"

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
