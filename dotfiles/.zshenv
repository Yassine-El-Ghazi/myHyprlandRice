# Normalize even noninteractive shells, before running environment hooks.
_myhypr_normalize_path() {
    _myhypr_remaining="/usr/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:${PATH-}"
    _myhypr_clean=''
    while :; do
        case $_myhypr_remaining in
            *:*) _myhypr_entry=${_myhypr_remaining%%:*}
                 _myhypr_remaining=${_myhypr_remaining#*:}; _myhypr_more=1 ;;
            *) _myhypr_entry=$_myhypr_remaining; _myhypr_more=0 ;;
        esac
        case $_myhypr_entry in
            /*)
                while [ "$_myhypr_entry" != / ] && [ "${_myhypr_entry%/}" != "$_myhypr_entry" ]; do
                    _myhypr_entry=${_myhypr_entry%/}
                done
                case ":$_myhypr_clean:" in
                    *":$_myhypr_entry:"*) ;;
                    *) _myhypr_clean="$_myhypr_clean:$_myhypr_entry" ;;
                esac
                ;;
        esac
        [ "$_myhypr_more" = 1 ] || break
    done
    PATH=${_myhypr_clean#:}
    export PATH
    unset _myhypr_remaining _myhypr_clean _myhypr_entry _myhypr_more
}
_myhypr_normalize_path
if [ -r "$HOME/.cargo/env" ]; then
    . "$HOME/.cargo/env"
fi
PATH="$PATH:$HOME/.foundry/bin"
_myhypr_normalize_path
unset -f _myhypr_normalize_path
