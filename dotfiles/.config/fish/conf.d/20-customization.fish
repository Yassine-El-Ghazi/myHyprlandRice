# -----------------------------------------------------
# CUSTOMIZATION
# -----------------------------------------------------

# -----------------------------------------------------
# Prompt
# -----------------------------------------------------
status is-interactive; or return

if command -q oh-my-posh
    oh-my-posh init fish --config "$HOME/.config/ohmyposh/zen.toml" | source
end
