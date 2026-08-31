#!/usr/bin/env bash
set -Eeuo pipefail

# CI job containers commonly forbid nested user namespaces. In that case this
# fixture verifies the exact fail-closed Bubblewrap contract, then executes the
# command through the real setpriv/env boundary. It is never used by production.

declare -a arguments=("$@") command_args=()
declare -A required_dirs=(
    [/home]=0
    [/boot]=0
    [/var]=0
    [/var/lib]=0
    [/var/lib/pacman]=0
)
unshare_pid=0
unshare_ipc=0
unshare_uts=0
unshare_net=0
die_with_parent=0
new_session=0
usr_bind=0
etc_bind=0
self_ro_binds=0
environment_bind=0
candidate_chdir=0
proc_mount=0
dev_mount=0
tmp_mount=0
run_mount=0
symlink_count=0
command_index=-1

index=0
while ((index < ${#arguments[@]})); do
    argument=${arguments[index]}
    case $argument in
        --unshare-pid) unshare_pid=1; ((index += 1)) ;;
        --unshare-ipc) unshare_ipc=1; ((index += 1)) ;;
        --unshare-uts) unshare_uts=1; ((index += 1)) ;;
        --unshare-net) unshare_net=1; ((index += 1)) ;;
        --die-with-parent) die_with_parent=1; ((index += 1)) ;;
        --new-session) new_session=1; ((index += 1)) ;;
        --ro-bind)
            ((index + 2 < ${#arguments[@]})) || exit 64
            source_path=${arguments[index + 1]}
            target_path=${arguments[index + 2]}
            [[ $source_path == "$target_path" ]] || exit 64
            case $source_path in
                /usr) usr_bind=1 ;;
                /etc) etc_bind=1 ;;
                *) ((self_ro_binds += 1)) ;;
            esac
            ((index += 3))
            ;;
        --bind)
            ((index + 2 < ${#arguments[@]})) || exit 64
            source_path=${arguments[index + 1]}
            target_path=${arguments[index + 2]}
            [[ $source_path == "$target_path" && \
                $source_path == */candidate-environment ]] || exit 64
            environment_bind=1
            ((index += 3))
            ;;
        --symlink)
            ((index + 2 < ${#arguments[@]})) || exit 64
            ((symlink_count += 1))
            ((index += 3))
            ;;
        --dir)
            ((index + 1 < ${#arguments[@]})) || exit 64
            directory=${arguments[index + 1]}
            if [[ -v required_dirs[$directory] ]]; then
                required_dirs[$directory]=1
            fi
            ((index += 2))
            ;;
        --proc)
            [[ ${arguments[index + 1]:-} == /proc ]] || exit 64
            proc_mount=1
            ((index += 2))
            ;;
        --dev)
            [[ ${arguments[index + 1]:-} == /dev ]] || exit 64
            dev_mount=1
            ((index += 2))
            ;;
        --tmpfs)
            case ${arguments[index + 1]:-} in
                /tmp) tmp_mount=1 ;;
                /run) run_mount=1 ;;
                *) exit 64 ;;
            esac
            ((index += 2))
            ;;
        --chdir)
            [[ ${arguments[index + 1]:-} == */candidate ]] || exit 64
            candidate_chdir=1
            ((index += 2))
            ;;
        /usr/bin/setpriv)
            command_index=$index
            break
            ;;
        *) exit 64 ;;
    esac
done

((unshare_pid && unshare_ipc && unshare_uts && unshare_net)) || exit 65
((die_with_parent && new_session && usr_bind && etc_bind)) || exit 65
((self_ro_binds >= 2 && environment_bind && candidate_chdir)) || exit 65
((proc_mount && dev_mount && tmp_mount && run_mount)) || exit 65
((symlink_count == 4 && command_index >= 0)) || exit 65
for directory in "${!required_dirs[@]}"; do
    ((required_dirs[$directory] == 1)) || exit 65
done

command_args=("${arguments[@]:command_index}")
[[ ${command_args[0]:-} == /usr/bin/setpriv && \
    ${command_args[1]:-} == --no-new-privs && \
    ${command_args[2]:-} == /usr/bin/env && \
    ${command_args[3]:-} == -i ]] || exit 65

exec "${command_args[0]}" "${command_args[1]}" \
    "${command_args[2]}" "${command_args[3]}" \
    MYHYPR_TEST_CONTRACT_BWRAP=1 "${command_args[@]:4}"
