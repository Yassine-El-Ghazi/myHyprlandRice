#!/usr/bin/env bash
set -Eeuo pipefail

config_root="${XDG_CONFIG_HOME:-$HOME/.config}"
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/myhypr"
theme_file="$config_root/myhypr/settings/walker-theme"
theme=myhypr

if [[ -r $theme_file ]]; then
    IFS= read -r candidate < "$theme_file" || true
    if [[ $candidate =~ ^[A-Za-z0-9._-]+$ && \
        -f $config_root/walker/themes/$candidate/style.css ]]; then
        theme=$candidate
    fi
fi

for command_name in walker elephant; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf 'Walker launcher requires the %s command. Run bootstrap again.\n' \
            "$command_name" >&2
        exit 1
    fi
done

if ! providers=$(elephant listproviders 2>/dev/null); then
    mkdir -p -- "$state_root"
    elephant >> "$state_root/elephant.log" 2>&1 &

    for _attempt in {1..40}; do
        sleep 0.05
        providers=$(elephant listproviders 2>/dev/null || true)
        [[ $providers == *desktopapplications* ]] && break
    done
fi

if [[ $providers != *desktopapplications* ]]; then
    printf '%s\n' \
        'Elephant desktop providers are unavailable. Run bootstrap to install them.' >&2
    exit 1
fi

exec walker -t "$theme" "$@"
