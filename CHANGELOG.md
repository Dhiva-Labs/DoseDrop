# Changelog

All notable changes to DoseDrop are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-10-16

### Added

- Linux arm64 and Windows arm64 builds, next to the existing x64 ones. CI
  builds, tests and smoke-runs the app on native arm64 runners; each release
  carries `dosedrop_<version>-1_arm64.deb`,
  `DoseDrop-<version>-linux-arm64.tar.gz` and
  `DoseDrop-<version>-windows-arm64.zip`. The snap and the Microsoft Store
  package build for arm64 too.
- Windows desktop app: system tray with close-to-tray, full-screen alarm with
  sound, a single running instance, Taken / Snooze / Skip / Log water buttons
  on the toast notifications, and a "Start DoseDrop at login" setting that
  follows Windows (Settings > Apps > Startup) when installed from the
  Microsoft Store package. Packaged as a zip
  (`DoseDrop-<version>-windows-<arch>.zip`) and as a Microsoft Store MSIX
  (`msix_config` in `pubspec.yaml`).
- Snap packaging (strict confinement, core22) for amd64 and arm64: tray,
  notifications, alarm sound and start at login.
- A privacy policy (`PRIVACY.md`): DoseDrop stores everything in one local
  file and makes no network connections.

### Changed

- The Linux tray fixes (the tray menu was never installed because setting the
  tooltip threw first; a sandboxed run passed the icon as a bare name instead
  of a path) are part of the app itself, so the `.deb` and tarball get them too.
- The release workflow attaches the packages of every architecture it builds
  to a published release and leaves files that are already attached untouched.
- Updated `jni` to 1.0.3, which compiles on Linux arm64.

### Fixed

- Windows: the alarm sound stayed silent when the user name contained an
  apostrophe (for example `O'Neil`).

## [1.0.0] - 2026-07-28

First release: escalating dose reminders, water reminders, history with
streaks and adherence charts, system tray on Linux, Android and Linux x64
packages.
