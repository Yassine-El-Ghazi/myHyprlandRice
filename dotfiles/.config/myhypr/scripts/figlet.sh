#!/usr/bin/env bash
set -Eeuo pipefail

figlet -f smslant "Figlet"
printf '\n'
# ------------------------------------------------
# Script to create ascii font based header on user input
# and copy the result to the clipboard
# -----------------------------------------------------

read -r -p 'Enter the text for ASCII encoding: ' mytext
output_file="$HOME/figlet.txt"

{
    printf 'cat <<"EOF"\n'
    figlet -f smslant "$mytext"
    printf '\nEOF\n'
} > "$output_file"
wl-copy < "$output_file"

printf 'Text copied to the clipboard and saved to %s\n' "$output_file"
