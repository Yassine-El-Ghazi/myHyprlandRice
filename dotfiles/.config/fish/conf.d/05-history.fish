umask 077
status is-interactive; or return

function fish_should_add_to_history
    not string match -qr '^ ' -- "$argv[1]"
end

set -l data_root "$HOME/.local/share"
if set -q XDG_DATA_HOME; and test -n "$XDG_DATA_HOME"
    set data_root "$XDG_DATA_HOME"
end
if not /usr/bin/python3 "$HOME/.config/myhypr/bin/shell-history.py" "$data_root/fish/fish_history"
    set -g fish_history ''
end
