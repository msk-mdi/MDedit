#!/bin/bash
# Assembles MdEdit.app around the SwiftPM binaries.
# Usage: Scripts/make-app.sh [debug|release] [--sandbox]
#
# Without a signing identity the app is ad-hoc signed: enough to run it here,
# not to distribute it. To sign for distribution and notarize, set
#   MDEDIT_SIGN_IDENTITY  "Developer ID Application: Name (TEAMID)"
#   MDEDIT_NOTARY_PROFILE a notarytool keychain profile, made once with
#                         xcrun notarytool store-credentials <profile> ...
# --sandbox signs with Resources/MdEdit-Sandbox.entitlements (App Sandbox, as
# the Mac App Store requires) instead of the hardened runtime alone.
# MDEDIT_SWIFT_FLAGS passes extra flags to swift build (Homebrew sets
# --disable-sandbox, as its own sandbox forbids SwiftPM's).
set -euo pipefail

CONFIG=debug
SANDBOX=0
for argument in "$@"; do
	case "$argument" in
		debug|release) CONFIG="$argument" ;;
		--sandbox) SANDBOX=1 ;;
		*) echo "usage: $0 [debug|release] [--sandbox]" >&2; exit 2 ;;
	esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

read -r -a FLAGS <<< "${MDEDIT_SWIFT_FLAGS:-}"
swift build -c "$CONFIG" ${FLAGS[@]+"${FLAGS[@]}"} --product MdEdit
swift build -c "$CONFIG" ${FLAGS[@]+"${FLAGS[@]}"} --product MdEditQuickLook
BIN="$(swift build -c "$CONFIG" ${FLAGS[@]+"${FLAGS[@]}"} --show-bin-path)"

APP="$ROOT/build/MdEdit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/MdEdit" "$APP/Contents/MacOS/MdEdit"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$ROOT/Resources/MarkdownDocument.icns" "$APP/Contents/Resources/"
cp "$ROOT/Resources/Help/"*.md "$APP/Contents/Resources/"
# Translations: the catalog compiles to one .lproj folder per language.
# xcstringstool comes with Xcode, not the Command Line Tools; without it the
# app is English only, as it is anyway until there are translations.
if xcrun --find xcstringstool >/dev/null 2>&1; then
	xcrun xcstringstool compile "$ROOT/Resources/Localizable.xcstrings" --output-directory "$APP/Contents/Resources" >/dev/null
fi
# KaTeX and Mermaid for offline math and diagrams, if Scripts/fetch-vendor.sh has run.
if [ -d "$ROOT/Resources/vendor" ]; then
	cp -R "$ROOT/Resources/vendor" "$APP/Contents/Resources/vendor"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The build number is the commit count, so every release build is higher.
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"

# The Quick Look extension, with the app's version.
APPEX="$APP/Contents/PlugIns/MdEditQuickLook.appex"
mkdir -p "$APPEX/Contents/MacOS"
cp "$BIN/MdEditQuickLook" "$APPEX/Contents/MacOS/MdEditQuickLook"
cp "$ROOT/Resources/QuickLook/Info.plist" "$APPEX/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$APPEX/Contents/Info.plist"

# Inside out: the extension first, then the app around it.
IDENTITY="${MDEDIT_SIGN_IDENTITY:--}"
SIGN=(codesign --force --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ]; then
	SIGN+=(--options runtime --timestamp)
fi
"${SIGN[@]}" --entitlements "$ROOT/Resources/QuickLook/MdEditQuickLook.entitlements" "$APPEX"
if [ "$SANDBOX" = 1 ]; then
	"${SIGN[@]}" --entitlements "$ROOT/Resources/MdEdit-Sandbox.entitlements" "$APP"
else
	"${SIGN[@]}" "$APP"
fi
codesign --verify --strict "$APP"

if [ -n "${MDEDIT_NOTARY_PROFILE:-}" ]; then
	if [ "$IDENTITY" = "-" ]; then
		echo "notarizing needs MDEDIT_SIGN_IDENTITY too" >&2
		exit 1
	fi
	ZIP="$ROOT/build/MdEdit-notarize.zip"
	ditto -c -k --keepParent "$APP" "$ZIP"
	xcrun notarytool submit "$ZIP" --keychain-profile "$MDEDIT_NOTARY_PROFILE" --wait
	xcrun stapler staple "$APP"
	rm -f "$ZIP"
fi

echo "built $APP ($VERSION, build $BUILD)"
