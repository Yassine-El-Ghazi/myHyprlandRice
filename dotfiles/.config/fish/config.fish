# Keep private or host-specific Fish settings outside version control.
if test -r "$HOME/.config/fish/config.local.fish"
    source "$HOME/.config/fish/config.local.fish"
end
