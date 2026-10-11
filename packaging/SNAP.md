# Packaging DoseDrop as a Snap

`snap/snapcraft.yaml` builds the Linux desktop app from source into a strictly
confined, `core22` + `gnome` extension snap named `dosedrop`. It follows the
same pattern as BranchPilot and ApiWorkbench (`plugin: flutter`, built inside
LXD so the binary matches the snap's runtime libraries).

## Building

```sh
snapcraft pack --use-lxd        # -> dosedrop_<version>_amd64.snap
```

`snap/` carries everything the build needs: the launcher entry and icon
(`snap/gui/`), the `aplay` stand-in (`snap/local/aplay`) and the tray patch
(`snap/local/tray-linux.patch`). `version` in `snapcraft.yaml` is set by hand
and must match `pubspec.yaml`.

## Publishing

```sh
snapcraft register dosedrop            # once
snapcraft upload --release=stable dosedrop_<version>_amd64.snap
```

Everything used is auto-connected or needs no review, so a build should pass
the automated checks and be releasable at once. Check `snapcraft revisions
dosedrop` after an upload: a revision that lands in the manual-review queue
blocks every later release of the snap until it is rejected or approved.

## Confinement

Plugs: `desktop`, `desktop-legacy`, `wayland`, `x11`, `gsettings`, `opengl`
(all from the `gnome` extension), `unity7` and `audio-playback`. All of them
connect automatically on a desktop; nothing needs `snap connect`. There is no
`home`, `network` or `alsa` plug: the app keeps one JSON file under its own
data directory and never touches the network.

`unity7` is not strictly required on current snapd: with it disconnected, the
tray and notifications still worked on snapd 2.77. It is kept because the
other snaps in this house use it and older snapd releases may depend on it for
the tray and notification D-Bus rules; drop it if a store reviewer objects.

| Feature | Under strict confinement |
|---|---|
| Window, theme, fonts | Works (GTK/Mesa come from the `gnome-42-2204` content snap). |
| Notifications | Works. The Taken / Snooze / Skip actions and the critical urgency reach `org.freedesktop.Notifications`. |
| System tray | Works (see "Tray patch" below). The StatusNotifierItem and its D-Bus menu register with the watcher, and the menu entries (Open, Pause 1 hour, Quit) act on the app. |
| Alarm sound | Works through PulseAudio or PipeWire via `audio-playback`. See "Alarm sound". |
| Start at login | Works. See "Autostart". |
| Timezone lookup | The app runs `timedatectl`, which a confined snap may not execute, so a `sh: timedatectl: Permission denied` line is logged at start-up. The plugin falls back to `/etc/timezone`; the value only matters for Android's scheduled notifications, so desktop reminders are unaffected. |

### Alarm sound

The app loops its alarm by spawning `aplay -q <wav>` and killing the process to
stop it. A confined snap cannot open `/dev/snd` without the manually connected
`alsa` interface, so `snap/local/aplay` (installed as `$SNAP/bin/aplay`, which
is on `PATH`) replaces it with `exec paplay <wav>` from `pulseaudio-utils`,
which uses the sound-server socket that `audio-playback` grants. `exec` keeps
the process id, so the app's `kill` still stops the sound. A system that has
only raw ALSA and no PulseAudio/PipeWire gets no alarm sound; the full-screen
alarm and the notification still appear.

### Autostart

"Start DoseDrop at login" makes the app write
`$HOME/.config/autostart/DoseDrop.desktop` (the file name is the app name given
to `launch_at_startup`). Inside a snap `$HOME` is `$SNAP_USER_DATA`, which is
where snapd's session agent looks, so the app declares `autostart:
DoseDrop.desktop`. snapd ignores the `Exec=` line in that file and starts the
app as `snap run dosedrop`. If the app is ever given a different autostart
name, the `autostart:` key must follow it. The app does not start minimised, so
the window appears at login.

### Tray patch

`snap/local/tray-linux.patch` is applied to `lib/services/tray_service.dart`
during `override-pull`. It fixes two defects that also exist in the `.deb`:

* `trayManager.setToolTip` is not implemented by the Linux AppIndicator
  backend. It throws `MissingPluginException`, which `initTray` caught for the
  whole block, so `_applyMenu()` never ran: the tray icon had an empty menu and
  there was no way to reopen a window that had been closed to the tray, or to
  quit. The patch isolates the tooltip call.
* Inside a sandbox, `tray_manager` hands the icon argument straight to the
  AppIndicator instead of resolving it against the bundle, so the desktop was
  asked for an icon literally named `assets/icon/tray.png` and showed a missing
  icon. The patch passes an absolute path, which is what a non-sandboxed run
  resolves to anyway.

The build skips the patch when the change is already in the source tree, so it
can be deleted once these fixes are upstream.

### Why there is a `cleanup` part

The snap stages `libayatana-appindicator3-1` (which depends on GTK) and
`pulseaudio-utils`. The Ubuntu archive copies of GTK, GLib, Cairo, Pango, X11
and so on then sit ahead of the content snap's on `LD_LIBRARY_PATH`. With that
mix `eglInitialize` fails, Flutter cannot create a rendering surface and the
window stays black. The `cleanup` part deletes every staged file that the
content snap also ships. It also takes the snap from 40 MB to 15 MB. The
content snap ships `libayatana-appindicator3` itself, so after the cleanup the
tray library is the content snap's.

## Testing without a desktop

The tray, notification and sound paths can be checked headlessly in a VM:
run the app under `xvfb-run`, own `org.kde.StatusNotifierWatcher` and
`org.freedesktop.Notifications` on the session bus with a small script that
logs what it receives, and run PulseAudio with a null sink (`pactl list
sink-inputs` shows `paplay` while an alarm rings). A medication seeded to fall
due a minute or two ahead (`tools/seed_demo.dart`) exercises the full alarm
path. Under Xvfb with no GPU, Mesa falls back to software rendering and logs
`libEGL warning: DRI3 error`; that is expected.

## Releasing a new version

1. Bump `version` in `pubspec.yaml` and in `snap/snapcraft.yaml`.
2. `snapcraft pack --use-lxd`, then install the result with `--dangerous` and
   check the window, a tray round trip and an alarm.
3. Upload and release as above.
