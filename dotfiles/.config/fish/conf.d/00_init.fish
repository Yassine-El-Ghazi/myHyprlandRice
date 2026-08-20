# -----------------------------------------------------
# INIT
# -----------------------------------------------------

set -g fish_greeting ""

# -----------------------------------------------------
# Exports
# -----------------------------------------------------
set -gx EDITOR nvim
set -gx VISUAL $EDITOR

# Normalize inherited PATH values without persisting host state to
# fish_variables. Empty entries are intentionally discarded because they make
# the current directory executable through PATH.
set -l clean_path
for path_entry in $PATH
    if test "$path_entry" != /
        set path_entry (string replace -r '/+$' '' -- "$path_entry")
    end
    test -n "$path_entry"; or continue
    contains -- "$path_entry" $clean_path; or set -a clean_path "$path_entry"
end
set -gx PATH $clean_path

fish_add_path --path --move $HOME/.config/myhypr/bin $HOME/.local/bin \
    $HOME/.cargo/bin $HOME/go/bin /usr/lib/ccache/bin

if command -q go
    set -l go_path (go env GOPATH 2>/dev/null)
    test -n "$go_path"; and fish_add_path --path "$go_path/bin"
end
