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
for config_file in "$HOME"/.config/zshrc/*(.N); do
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
