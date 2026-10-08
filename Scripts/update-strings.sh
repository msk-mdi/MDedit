#!/bin/bash
# Extracts every localizable string in the app into Resources/Localizable.xcstrings,
# the catalog translators edit. Scripts/make-app.sh compiles it into the bundle's
# .lproj folders.
#
# The compiler does the extracting, so it finds `String(localized:)` and any
# string literal passed where a `String.LocalizationValue` is expected — the
# menu titles in MainMenu.swift, for one.
# Usage: Scripts/update-strings.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift build --product MdEdit --scratch-path "$WORK/build" \
	-Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$WORK/strings" >/dev/null

CATALOG="$ROOT/Resources/Localizable.xcstrings"
if [ ! -f "$CATALOG" ]; then
	printf '{\n  "sourceLanguage" : "en",\n  "strings" : {\n\n  },\n  "version" : "1.0"\n}\n' > "$CATALOG"
fi
DATA=()
for file in "$WORK"/strings/*.stringsdata; do DATA+=(--stringsdata "$file"); done
xcrun xcstringstool sync "$CATALOG" "${DATA[@]}"
echo "updated $CATALOG ($(xcrun xcstringstool print "$CATALOG" | wc -l | tr -d ' ') keys)"
