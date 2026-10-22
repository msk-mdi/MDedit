#!/bin/bash
# Downloads KaTeX and Mermaid into Resources/vendor, so Scripts/make-app.sh
# bundles them and HTML export can embed them for pages that work offline.
# Without them, exported pages load both from jsDelivr as before.
# Both come from npm, and each tarball must match its pinned SHA-256: what
# is fetched here ships inside every release. To update a version, change it
# and its hash (shasum -a 256 the new tarball), and the integrity hashes in
# HTMLRenderer.swift and Typesetter.swift.
# Usage: Scripts/fetch-vendor.sh
set -euo pipefail

KATEX=0.19.0
MERMAID=11.17.2
KATEX_SHA256=d8e49f2fea6eeed7cdae2cf4fd48e2f1d348758aa9e5740715e4533c2c96d1ee
MERMAID_SHA256=6ad2f42c3fc26bbf9e45cbb6d11898972573ea52b33a5f4ff51952899f950ffd
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Resources/vendor"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rm -rf "$VENDOR"
mkdir -p "$VENDOR/katex" "$VENDOR/mermaid"

# Downloads a package's tarball and stops unless it has the expected hash.
fetch() {
	local name="$1" version="$2" sha256="$3"
	curl -fsSL "https://registry.npmjs.org/$name/-/$name-$version.tgz" -o "$TMP/$name.tgz"
	echo "$sha256  $TMP/$name.tgz" | shasum -a 256 -c --quiet - || {
		echo "$name $version does not match its pinned SHA-256" >&2
		exit 1
	}
	mkdir -p "$TMP/$name"
	tar -xzf "$TMP/$name.tgz" -C "$TMP/$name"
}

fetch katex "$KATEX" "$KATEX_SHA256"
fetch mermaid "$MERMAID" "$MERMAID_SHA256"

cp "$TMP/katex/package/dist/katex.min.css" "$TMP/katex/package/dist/katex.min.js" "$VENDOR/katex/"
mkdir -p "$VENDOR/katex/contrib" "$VENDOR/katex/fonts"
cp "$TMP/katex/package/dist/contrib/auto-render.min.js" "$VENDOR/katex/contrib/"
cp "$TMP/katex/package/dist/fonts/"*.woff2 "$VENDOR/katex/fonts/"
cp "$TMP/katex/package/LICENSE" "$VENDOR/katex/LICENSE"

cp "$TMP/mermaid/package/dist/mermaid.min.js" "$TMP/mermaid/package/LICENSE" "$VENDOR/mermaid/"

echo "fetched KaTeX $KATEX and Mermaid $MERMAID into $VENDOR"
