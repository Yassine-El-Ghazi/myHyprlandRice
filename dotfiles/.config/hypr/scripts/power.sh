#!/usr/bin/env bash
set -Eeuo pipefail
#    ___                    
#   / _ \___ _    _____ ____
#  / ___/ _ \ |/|/ / -_) __/
# /_/   \___/__,__/\__/_/   
#                           

terminate_clients() {
	local timeout=5
	local deadline pid
	local -a client_pids=()

	mapfile -t client_pids < <(hyprctl clients -j | jq -r '.[].pid | select(. > 1)' | sort -nu)
	for pid in "${client_pids[@]}"; do
		[[ $pid =~ ^[0-9]+$ && $pid -ne $$ ]] || continue
		printf ':: Sending SIGTERM to PID %s\n' "$pid"
		kill -TERM "$pid" 2>/dev/null || true
	done

	deadline=$((SECONDS + timeout))
	for pid in "${client_pids[@]}"; do
		while kill -0 "$pid" 2>/dev/null && ((SECONDS < deadline)); do
			sleep 0.2
		done
	done
	"$HOME/.config/myhypr/listeners.sh" --stopall || true
}

action=${1:-}
case $action in
    exit|lock|reboot|shutdown|suspend|hibernate) ;;
    *)
        printf 'Usage: %s {exit|lock|reboot|shutdown|suspend|hibernate}\n' "${0##*/}" >&2
        exit 2
        ;;
esac

if [[ $action == "exit" ]]; then
	echo ":: Exit"
	terminate_clients
	sleep 0.5
	hyprctl dispatch exit
	sleep 2
fi

if [[ $action == "lock" ]]; then
	echo ":: Lock"
	sleep 0.5
	pgrep -x hyprlock >/dev/null 2>&1 || hyprlock
fi

if [[ $action == "reboot" ]]; then
	echo ":: Reboot"
	terminate_clients
	sleep 0.5
	systemctl reboot
fi

if [[ $action == "shutdown" ]]; then
	echo ":: Shutdown"
	terminate_clients
	sleep 0.5
	systemctl poweroff
fi

if [[ $action == "suspend" ]]; then
	echo ":: Suspend"
	sleep 0.5
	systemctl suspend
fi

if [[ $action == "hibernate" ]]; then
	echo ":: Hibernate"
	sleep 1
	systemctl hibernate
fi
