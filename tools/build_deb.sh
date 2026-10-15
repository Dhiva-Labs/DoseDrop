#!/usr/bin/env bash
# Builds dosedrop_<version>-1_<arch>.deb from the Linux release bundle.
#
# Run from the repo root after `flutter build linux --release`:
#
#     tools/build_deb.sh [output-dir]        # default output-dir: dist/
#
# <arch> is the Debian architecture of the build machine (amd64 or arm64),
# which is also the only one `flutter build linux` can target, so the bundle
# is read from build/linux/x64/... on amd64 and build/linux/arm64/... on arm64.
#
# Needs python3 + Pillow (for the icon renders) and dpkg-deb.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT_DIR="${1:-dist}"
DEB_ARCH="$(dpkg --print-architecture)"
case "$DEB_ARCH" in
  amd64) FLUTTER_ARCH=x64 ;;
  arm64) FLUTTER_ARCH=arm64 ;;
  *)
    echo "error: unsupported architecture '$DEB_ARCH' (amd64 or arm64)" >&2
    exit 1
    ;;
esac
BUNDLE="build/linux/$FLUTTER_ARCH/release/bundle"
VERSION="$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)"

[ -x "$BUNDLE/dose_drop" ] || {
  echo "error: $BUNDLE/dose_drop not found — run 'flutter build linux --release' first" >&2
  exit 1
}

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/dosedrop"

mkdir -p \
  "$PKG/DEBIAN" \
  "$PKG/usr/lib/dosedrop" \
  "$PKG/usr/bin" \
  "$PKG/usr/share/applications" \
  "$PKG/usr/share/icons/hicolor/128x128/apps" \
  "$PKG/usr/share/icons/hicolor/256x256/apps" \
  "$PKG/usr/share/doc/dosedrop"

cp -r "$BUNDLE/." "$PKG/usr/lib/dosedrop/"

cat > "$PKG/usr/bin/dosedrop" <<'EOF'
#!/bin/sh
exec /usr/lib/dosedrop/dose_drop "$@"
EOF
chmod 0755 "$PKG/usr/bin/dosedrop"

cat > "$PKG/usr/share/applications/dosedrop.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=DoseDrop
Comment=Medication & water reminders that nag until you confirm
Exec=dosedrop
Icon=dosedrop
Terminal=false
Categories=Utility;
Keywords=medication;pills;tablets;water;reminder;health;
StartupWMClass=dose_drop
EOF

python3 tools/generate_tray_icon.py --size 128 \
  --out "$PKG/usr/share/icons/hicolor/128x128/apps/dosedrop.png" >/dev/null
python3 tools/generate_tray_icon.py --size 256 \
  --out "$PKG/usr/share/icons/hicolor/256x256/apps/dosedrop.png" >/dev/null

cat > "$PKG/usr/share/doc/dosedrop/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: dosedrop
Source: https://github.com/Dhiva-Labs/DoseDrop

Files: *
Copyright: $(date +%Y) Dhiva Labs
License: proprietary-freeware
 Distributed as a free application by Dhiva Labs.
EOF

INSTALLED_SIZE="$(du -sk "$PKG/usr" | cut -f1)"
cat > "$PKG/DEBIAN/control" <<EOF
Package: dosedrop
Version: ${VERSION}-1
Section: utils
Priority: optional
Architecture: ${DEB_ARCH}
Maintainer: Dhiva Labs <dhivakar101010@gmail.com>
Installed-Size: ${INSTALLED_SIZE}
Depends: libgtk-3-0t64 | libgtk-3-0, libayatana-appindicator3-1, alsa-utils
Homepage: https://github.com/Dhiva-Labs/DoseDrop
Description: Medication & water reminders that nag until you confirm
 Escalating dose reminders with Taken / Snooze / Skip actions, full-screen
 alarms, interval water reminders with a daily goal, and adherence history
 with streaks and weekly charts. Lives in the system tray; optional
 start-at-login.
EOF

mkdir -p "$OUT_DIR"
DEB="$OUT_DIR/dosedrop_${VERSION}-1_${DEB_ARCH}.deb"
dpkg-deb --build --root-owner-group "$PKG" "$DEB" >/dev/null
echo "built $DEB"
