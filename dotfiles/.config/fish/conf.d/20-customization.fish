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
# oh-my-posh init fish --config "$HOME/.config/ohmyposh/EDM115-newline.omp.json" | source
