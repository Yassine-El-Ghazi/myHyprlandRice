#    _               _              
#   | |__   __ _ ___| |__  _ __ ___ 
#   | '_ \ / _` / __| '_ \| '__/ __|
#  _| |_) | (_| \__ \ | | | | | (__ 
# (_)_.__/ \__,_|___/_| |_|_|  \___|
# 
# -----------------------------------------------------
# ML4W bashrc loader
# -----------------------------------------------------

# Override a modular file by placing a file with the same name in
# ~/.config/bashrc/custom, or keep machine-only settings in ~/.bashrc_custom.
# -----------------------------------------------------

# -----------------------------------------------------
# Load modular configuration
# -----------------------------------------------------

shopt -s nullglob
for config_file in "$HOME"/.config/bashrc/*; do
    [[ -f "$config_file" ]] || continue
    override_file="$HOME/.config/bashrc/custom/$(basename "$config_file")"
    if [[ -f "$override_file" ]]; then
        source "$override_file"
    else
        source "$config_file"
    fi
done
shopt -u nullglob
unset config_file override_file

# -----------------------------------------------------
# Load single customization file (if exists)
# -----------------------------------------------------

if [[ -r "$HOME/.bashrc_custom" ]]; then
    source "$HOME/.bashrc_custom"
fi
