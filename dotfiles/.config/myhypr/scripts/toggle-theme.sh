#!/usr/bin/env bash
set -Eeuo pipefail

config_root=${XDG_CONFIG_HOME:-$HOME/.config}
gtk3_settings="$config_root/gtk-3.0/settings.ini"
gtk4_settings="$config_root/gtk-4.0/settings.ini"
setting_name=gtk-application-prefer-dark-theme

read_preference() {
    awk -F= -v name="$setting_name" '$1 == name {print $2; exit}' "$1"
}

write_preference() {
    local target=$1
    local value=$2
    local temporary

    [[ -f $target && ! -L $target ]] || {
        printf 'GTK settings must be a regular local file: %s\n' "$target" >&2
        return 1
    }
    temporary=$(mktemp "${target%/*}/.settings.ini.XXXXXX")
    awk -F= -v name="$setting_name" -v value="$value" '
        BEGIN { found = 0 }
        $1 == name { print name "=" value; found = 1; next }
        { print }
        END { if (!found) exit 2 }
    ' "$target" > "$temporary" || {
        rm -f -- "$temporary"
        printf 'GTK color preference is missing from %s\n' "$target" >&2
        return 1
    }
    chmod --reference="$target" "$temporary"
    mv -- "$temporary" "$target"
}

[[ -f $gtk3_settings && ! -L $gtk3_settings ]] || {
    printf 'GTK3 settings are unavailable or still managed by Git: %s\n' \
        "$gtk3_settings" >&2
    exit 1
}
[[ -f $gtk4_settings && ! -L $gtk4_settings ]] || {
    printf 'GTK4 settings are unavailable or still managed by Git: %s\n' \
        "$gtk4_settings" >&2
    exit 1
}

case $(read_preference "$gtk3_settings") in
    1|true) next_preference=false; mode=light ;;
    0|false) next_preference=true; mode=dark ;;
    *)
        printf 'GTK3 color preference has an unsupported value.\n' >&2
        exit 1
        ;;
esac

# GTK3 is monitored by the theme listener, so update GTK4 first and GTK3 last.
write_preference "$gtk4_settings" "$next_preference"
write_preference "$gtk3_settings" "$next_preference"
printf 'Switched to %s theme.\n' "$mode"
