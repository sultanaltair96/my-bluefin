# vim: set ft=make :
#######################
### custom-system.just
#######################
## System-level commands.
##
## Nothing here runs automatically: image updates and logins never overwrite
## user configuration or change group membership. These recipes are the
## explicit, user-invoked way to do both.

# Add the current user to the docker and libvirt groups, creating them if needed.
[group('System')]
configure-dev-groups:
    #!/usr/bin/env bash
    set -euo pipefail

    # Fedora ships no /usr/lib/group entry to copy for either name, and both
    # daemons are opt-in for a fork, so create a group when it is missing rather
    # than assume a package provided it. Only the mutating commands escalate;
    # the checks run as the invoking user.
    CURRENT_USER="$(id -un)"
    DEV_GROUPS=(docker libvirt)
    MISSING=()

    for group in "${DEV_GROUPS[@]}"; do
        if ! getent group "${group}" >/dev/null; then
            echo "Creating the ${group} group"
            sudo groupadd --system "${group}"
        fi
        if ! id -nG "${CURRENT_USER}" | grep -qw "${group}"; then
            MISSING+=("${group}")
        fi
    done

    if ((${#MISSING[@]} == 0)); then
        echo "${CURRENT_USER} is already in: ${DEV_GROUPS[*]}"
        exit 0
    fi

    if command -v gum >/dev/null 2>&1; then
        if ! gum confirm "Add ${CURRENT_USER} to: ${MISSING[*]}?"; then
            echo "Cancelled."
            exit 0
        fi
    fi

    GROUP_LIST="$(IFS=,; echo "${MISSING[*]}")"
    sudo usermod --append --groups "${GROUP_LIST}" "${CURRENT_USER}"
    echo "Added ${CURRENT_USER} to: ${MISSING[*]}"
    echo "Log out and back in before using docker or libvirt without sudo."
