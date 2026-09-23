# vim: set ft=make :

# Apply the portable GNOME preferences captured from the source installation.
[group('Personalization')]
apply-gnome-settings:
    #!/usr/bin/env bash
    set -euo pipefail
    settings=/usr/share/my-bluefin/gnome-settings.dconf
    backup_dir="${HOME}/.local/state/my-bluefin"
    mkdir -p "${backup_dir}"
    dconf dump /org/gnome/ >"${backup_dir}/gnome-before-my-bluefin.dconf"
    dconf load /org/gnome/ <"${settings}"
    echo "GNOME settings applied. Log out and back in to refresh GNOME Shell."
    echo "Previous settings: ${backup_dir}/gnome-before-my-bluefin.dconf"
