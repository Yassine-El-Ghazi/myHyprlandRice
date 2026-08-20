#!/usr/bin/env bash
set -Eeuo pipefail

declare -a shell_names=()
declare -a shell_paths=()

for shell_name in bash zsh fish; do
    shell_path=$(command -v "$shell_name" 2>/dev/null || true)
    [[ -n $shell_path ]] || continue
    if [[ -r /etc/shells ]] && ! grep -Fxq -- "$shell_path" /etc/shells; then
        continue
    fi
    shell_names+=("$shell_name")
    shell_paths+=("$shell_path")
done

((${#shell_names[@]})) || {
    printf 'No supported login shell is installed. Run the repository bootstrap first.\n' >&2
    exit 1
}

shell_names+=(Cancel)
printf 'Select your preferred login shell. Shell integrations are managed by the package manifest.\n\n'
if command -v gum >/dev/null 2>&1; then
    selected=$(printf '%s\n' "${shell_names[@]}" | gum choose) || exit 0
else
    PS3='Shell: '
    select selected in "${shell_names[@]}"; do
        [[ -n $selected ]] && break
    done
fi

[[ $selected != Cancel ]] || {
    printf 'Shell change canceled.\n'
    exit 0
}

selected_path=''
for index in "${!shell_names[@]}"; do
    if [[ ${shell_names[$index]} == "$selected" ]]; then
        selected_path=${shell_paths[$index]}
        break
    fi
done
[[ -n $selected_path ]] || {
    printf 'Invalid shell selection: %s\n' "$selected" >&2
    exit 2
}

current_shell=$(getent passwd "$USER" | cut -d: -f7)
if [[ $current_shell == "$selected_path" ]]; then
    printf '%s is already your login shell.\n' "$selected"
    exit 0
fi

chsh -s "$selected_path"
printf 'Login shell changed to %s. It will apply at your next login.\n' "$selected"
