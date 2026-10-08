#!/bin/bash
# Packs build/MdEdit.app into build/MdEdit-<version>.dmg, with an
# Applications link to drag it onto. Run Scripts/make-app.sh release first.
# With MDEDIT_SIGN_IDENTITY and MDEDIT_NOTARY_PROFILE set, as for
# make-app.sh, the image is signed, notarized and stapled too.
# Usage: Scripts/make-dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/MdEdit.app"
[ -d "$APP" ] || { echo "no $APP: run Scripts/make-app.sh release first" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="$ROOT/build/MdEdit-$VERSION.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

ditto "$APP" "$STAGING/MdEdit.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "MdEdit $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

if [ -n "${MDEDIT_SIGN_IDENTITY:-}" ]; then
	codesign --force --timestamp --sign "$MDEDIT_SIGN_IDENTITY" "$DMG"
	if [ -n "${MDEDIT_NOTARY_PROFILE:-}" ]; then
		xcrun notarytool submit "$DMG" --keychain-profile "$MDEDIT_NOTARY_PROFILE" --wait
		xcrun stapler staple "$DMG"
	fi
fi

shasum -a 256 "$DMG"
