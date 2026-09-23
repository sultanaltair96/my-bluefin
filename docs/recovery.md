# Workstation recovery

The public OS image and the private user-state snapshot are separate. The OS
image alone cannot reproduce logged-in applications, an AppImage library, or
personal files. Never commit the recovery repository, password, or a raw dconf
dump to Git.

## Local encrypted snapshot

A restic repository is stored at:

```
~/.local/share/my-bluefin-recovery
```

Its password is stored separately with owner-only permissions at:

```
~/.config/my-bluefin/recovery-password
```

Copy the repository to an external disk or remote backup storage and save the
password in a password manager. A repository on the same PC is a migration
staging copy, NOT protection against loss or failure of that PC. Keep the signing
key backup (`~/.config/my-bluefin-signing`, if created) separately too; it is needed
to retain the custom image's update-signing identity.

The initial snapshot includes `.config`, Flatpak user data (`.var/app`),
`AppImages`, user launchers, wallpaper, fonts, icons, sounds, GNOME extensions,
keyrings, shell startup files, Git settings, and a full GNOME dconf export.
Caches and Steam game downloads are excluded. Documents, Downloads, projects,
SSH keys, containers, arbitrary `.local/share` application data, and Hermes data
are NOT covered by this selection. Back those up separately if wanted.

The initial copy was made while this PC was running. File integrity is checked,
but live browser/database consistency is not guaranteed. Close applications and
refresh the snapshot immediately before migration.

## Refresh before migration

Run from the original desktop session after closing applications:

```bash
umask 077
dconf dump /org/gnome/ > ~/.local/state/my-bluefin/gnome-full.dconf
restic -r ~/.local/share/my-bluefin-recovery \
  --password-file ~/.config/my-bluefin/recovery-password backup \
  --files-from ~/.local/state/my-bluefin/backup-paths.txt \
  --tag workstation-migration --exclude-caches \
  --exclude '**/Cache/**' --exclude '**/cache/**' \
  --exclude '**/GPUCache/**' --exclude '**/Code Cache/**' \
  --exclude '**/steamapps/**' --exclude '**/ShaderCache/**' \
  --exclude "$HOME/.config/my-bluefin/recovery-password"
restic -r ~/.local/share/my-bluefin-recovery \
  --password-file ~/.config/my-bluefin/recovery-password check --read-data
```

## Restore on another PC

1. Install the custom image and create the user `taanis` to retain paths in
   existing AppImage launchers and wallpaper settings. A different username
   requires rewriting those references.
2. Connect networking; allow the declared Flatpaks to install. Run
   `ujust install-default-apps` for the Homebrew tools.
3. Copy the encrypted repository and password securely to the new PC.
4. Restore to a staging directory, not on top of a running desktop:

   ```bash
   umask 077
   mkdir -p ~/restore-staging
   restic -r /path/to/my-bluefin-recovery \
     --password-file /path/to/recovery-password snapshots
   restic -r /path/to/my-bluefin-recovery \
     --password-file /path/to/recovery-password restore SNAPSHOT_ID \
     --target ~/restore-staging --verify
   ```

5. Review the restored `home/taanis` tree. Copy selected configuration and data
   while the relevant applications are closed, preferably from a text console
   with the graphical user logged out. Back up any existing destination files.
   Do not blindly restore `.config/monitors.xml` or hardware-specific settings
   from a different PC. Keyrings may require the old login password to unlock.
6. Import the full GNOME preferences from your private snapshot if desired:

   ```bash
   dconf dump /org/gnome/ > ~/gnome-before-restore.dconf
   dconf load /org/gnome/ < ~/restore-staging/home/taanis/.local/state/my-bluefin/gnome-full.dconf
   ```

7. Log out and back in. Reset Resource Monitor device selection for the new
   disk/GPU, verify wallpaper paths, extension compatibility, and application
   launchers. The full private dump includes old hardware references and some
   stale extension names; the public image defaults are the more portable option.
8. Reauthenticate Tailscale and other services as needed. Machine identity and
   live service state are deliberately not cloned.

## What reproducible means here

The base operating system is pinned to an immutable container digest and the
built image can be deployed by digest. GNOME extension downloads added by this
project are checksum-pinned. The published artifact and its checksum identify a
specific installer.

Flatpak and Homebrew declarations reproduce the application selection, not an
indefinitely frozen set of package versions: the upstream repositories supply
current packages. Private state comes from the dated encrypted snapshot. A new
GPU architecture or major GNOME release still requires compatibility testing.
