# -----------------------------------------------------
# ALIASES
# -----------------------------------------------------

# -----------------------------------------------------
# General
# -----------------------------------------------------
alias c='clear'
alias nf='fastfetch'
alias pf='fastfetch'
alias ff='fastfetch'
alias ls='eza -a --icons=always'
alias ll='eza -al --icons=always'
alias lt='eza -a --tree --level=1 --icons=always'
alias shutdown='systemctl poweroff'
alias v='$EDITOR'
alias vim='$EDITOR'
alias ts='~/.config/myhypr/scripts/arch/snapshot.sh'
alias wifi='nmtui'
alias cleanup='~/.config/myhypr/scripts/arch/cleanup.sh'

# -----------------------------------------------------
# MyHypr controls
# -----------------------------------------------------
alias myhypr='~/.config/myhypr/bin/myhyprctl welcome'
alias myhypr-settings='~/.config/myhypr/bin/myhyprctl settings'
alias myhypr-calendar='~/.config/myhypr/bin/myhyprctl calendar'
alias myhypr-sidebar='~/.config/myhypr/bin/myhyprctl sidebar'
alias myhypr-doctor='~/.config/myhypr/bin/myhyprctl doctor'
alias myhypr-update='~/.config/myhypr/bin/myhyprctl update'

# -----------------------------------------------------
# Window Managers
# -----------------------------------------------------

alias Qtile='startx'
# Hyprland with Hyprland

# -----------------------------------------------------
# Git
# -----------------------------------------------------
alias gs="git status"
alias ga="git add"
alias gc="git commit -m"
alias gp="git push"
alias gpl="git pull"
alias gst="git stash"
alias gsp="git stash; git pull"
alias gfo="git fetch origin"
alias gcheck="git checkout"
# -----------------------------------------------------
# Scripts
# -----------------------------------------------------
alias ascii='~/.config/myhypr/scripts/figlet.sh'

# -----------------------------------------------------
# System
# -----------------------------------------------------
alias update-grub='sudo grub-mkconfig -o /boot/grub/grub.cfg'
