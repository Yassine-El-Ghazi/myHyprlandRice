# shellcheck shell=bash disable=SC1090
#    _               _              
#   | |__   __ _ ___| |__  _ __ ___ 
#   | '_ \ / _` / __| '_ \| '__/ __|
#  _| |_) | (_| \__ \ | | | | | (__ 
# (_)_.__/ \__,_|___/_| |_|_|  \___|
# 
# -----------------------------------------------------
# MyHyprlandRice bashrc loader
# -----------------------------------------------------

# Override a modular file by placing a file with the same name in
# ~/.config/bashrc/custom, or keep machine-only settings in ~/.bashrc_custom.
# -----------------------------------------------------

# -----------------------------------------------------
# Load modular configuration
# -----------------------------------------------------

_myhypr_normalize_path() {
    local entry seen duplicate
    local -a entries clean_entries=(/usr/local/sbin /usr/local/bin /usr/bin /bin /usr/sbin)
    IFS=: read -r -a entries <<< "${PATH:-}"
    for entry in "${entries[@]}"; do
        while [[ $entry != / && $entry == */ ]]; do entry=${entry%/}; done
        [[ $entry == /* ]] || continue
        duplicate=false
        for seen in "${clean_entries[@]}"; do
            [[ $seen != "$entry" ]] || { duplicate=true; break; }
        done
        [[ $duplicate == true ]] || clean_entries+=("$entry")
    done
    local IFS=:
    export PATH="${clean_entries[*]}"
}
# Apply before module commands and after customizations.
_myhypr_normalize_path
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
    # shellcheck source=/dev/null
    source "$HOME/.bashrc_custom"
fi
_myhypr_normalize_path
unset -f _myhypr_normalize_path
