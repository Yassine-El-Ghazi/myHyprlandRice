#!/usr/bin/env bash
# shellcheck disable=SC2016  # Match literal, portable $HOME path tokens.
set -Eeuo pipefail

CONFIG_FILE="$HOME/.quicklinks"
tilde='~'

trim() {
    local value=$1
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

if [[ ! -f $CONFIG_FILE ]]; then
    printf 'Quicklinks file not found: %s\n' "$CONFIG_FILE"
    printf 'Format: Name | Description | executable and arguments\n'
    read -r -p 'Create a template now? [y/N] ' reply
    if [[ $reply == [yY] || $reply == [yY][eE][sS] ]]; then
        umask 077
        printf '%s\n' \
            'Dotfiles | Open the repository | xdg-open ~/Projects/myHyprlandRice' \
            > "$CONFIG_FILE"
        printf 'Template created. Edit it, then run this command again.\n'
    fi
    exit 1
fi

selected_line=$(fzf \
    --style full \
    --height 40% --layout reverse --border \
    --prompt '🚀 Quick Access: ' \
    --delimiter '|' --with-nth 1..3 \
    < "$CONFIG_FILE") || exit 0
[[ -n $selected_line ]] || exit 0

IFS='|' read -r _name _description raw_command <<< "$selected_line"
raw_command=$(trim "$raw_command")
[[ -n $raw_command ]] || {
    printf 'The selected quicklink has no command.\n' >&2
    exit 1
}

# Quicklinks are argument lists, not shell programs. Operators such as pipes,
# redirections, and command substitutions are deliberately treated as text.
read -r -a command_parts <<< "$raw_command"
for index in "${!command_parts[@]}"; do
    case ${command_parts[index]} in
        "$tilde") command_parts[index]=$HOME ;;
        "$tilde/"*) command_parts[index]="$HOME/${command_parts[index]#"$tilde/"}" ;;
        '$HOME') command_parts[index]=$HOME ;;
        '$HOME/'*) command_parts[index]="$HOME/${command_parts[index]#\$HOME/}" ;;
    esac
done
command -v "${command_parts[0]}" >/dev/null 2>&1 || {
    printf 'Quicklink command is unavailable: %s\n' "${command_parts[0]}" >&2
    exit 127
}

printf 'Executing:'
printf ' %q' "${command_parts[@]}"
printf '\n'
exec "${command_parts[@]}"
