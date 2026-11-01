# Flatpak

`com.dhivalabs.dose_drop.yml` builds the Flatpak from the installed tree of
the .deb, so it ships the same binary as every other Linux package.

## How CI builds it

The `distros` job in `.github/workflows/desktop.yml` unpacks the .deb, cleans
the tree (`packaging/linux-distros/pack.sh`, which drops the Debian-only files
and `libdartjni.so`, see `distro.conf`) and adds what the GNOME runtime lacks:
the tray icon's libraries (libayatana-appindicator3 and its libayatana-indicator3,
libayatana-ido3, libdbusmenu-glib and libdbusmenu-gtk3) and `aplay`, copied
from the Ubuntu 24.04 packages that the .deb depends on. The `flatpak` job
unpacks it into `packaging/flatpak/tree/` and runs flatpak-builder in the
`ghcr.io/flathub-infra/flatpak-github-actions:gnome-51` image, on x86_64 and
aarch64. It then installs the bundle, checks every ELF file with ldd against
the GNOME 51 runtime, plays the alarm sound with the bundled aplay (to ALSA's
null device), and starts the app under Xvfb until the Dart code has titled
the window "DoseDrop" (`x11_window.py`; the image has no xdotool) and created
its data folder.

The bundle, `dosedrop-<version>-<arch>.flatpak`, refers to Flathub for its
runtime:

```sh
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user ./dosedrop-<version>-x86_64.flatpak
flatpak run com.dhivalabs.dose_drop
```

## Sandbox

- `--talk-name=org.freedesktop.Notifications`: reminders are notifications,
  and the notifications plugin talks to the notification server directly.
- `--talk-name=org.kde.StatusNotifierWatcher`: the tray icon.
- `--socket=pulseaudio`: the alarm sound (aplay goes through the runtime's
  ALSA-to-PulseAudio plugin).
- No network and no file access: DoseDrop keeps its data in its own folder
  (`~/.var/app/com.dhivalabs.dose_drop/data`).
- Start at login writes `~/.config/autostart/DoseDrop.desktop`, which the
  sandbox cannot reach, so the setting has no effect in the Flatpak (the app
  treats a failed write as "off", as it does on any read-only desktop).

## Releases

Add a `<release>` line to `com.dhivalabs.dose_drop.metainfo.xml` with each
version bump; the CI fails when the version in `pubspec.yaml` is missing
there.

## Flathub

A Flathub submission would differ: the `tree` directory source becomes an
`archive` source (the release's `dosedrop_<version>-1_amd64.deb` / `_arm64.deb`,
with `only-arches` and a sha256 each, unpacked with `ar` and `tar`, and
`libdartjni.so` removed), the tray libraries and aplay are built from source
as manifest modules instead of copied from Ubuntu, and the manifest goes to a
new `flathub/com.dhivalabs.dose_drop` repository through Flathub's review.
Flathub also expects an open-source licence or an explicit redistribution
grant for a proprietary app. Nothing is published from this repository.
