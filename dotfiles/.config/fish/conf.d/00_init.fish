# -----------------------------------------------------
# INIT
# -----------------------------------------------------

set -g fish_greeting ""

# -----------------------------------------------------
# Exports
# -----------------------------------------------------
set -gx EDITOR nvim
set -gx VISUAL $EDITOR

# System commands take precedence over local tools, including in nested shells.
# Keep changes local to this process, not persistent fish_variables state.
set -l inherited_path $PATH
set -l clean_path /usr/local/sbin /usr/local/bin /usr/bin /bin /usr/sbin
for path_entry in "$HOME/.config/myhypr/bin" "$HOME/.local/bin" \
        "$HOME/.cargo/bin" "$HOME/go/bin" /usr/lib/ccache/bin $inherited_path
    if test "$path_entry" != /
        set path_entry (string replace -r '/+$' '' -- "$path_entry")
    end
    # Empty and relative entries make executable lookup depend on the cwd.
    string match -q '/*' -- "$path_entry"; or continue
    test -d "$path_entry"; or continue
    contains -- "$path_entry" $clean_path; or set -a clean_path "$path_entry"
end
set -gx PATH $clean_path

if test -x /usr/bin/go
    for go_path in (string split : -- (/usr/bin/go env GOPATH 2>/dev/null))
        string match -q '/*' -- "$go_path"; or continue
        fish_add_path --path --append "$go_path/bin"
    end
end
