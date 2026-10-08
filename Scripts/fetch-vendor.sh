#!/bin/bash
# Downloads KaTeX and Mermaid into Resources/vendor, so Scripts/make-app.sh
# bundles them and HTML export can embed them for pages that work offline.
# Without them, exported pages load both from jsDelivr as before.
# Usage: Scripts/fetch-vendor.sh
set -euo pipefail

KATEX=0.16.11
MERMAID=11.4.1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Resources/vendor"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rm -rf "$VENDOR"
mkdir -p "$VENDOR/katex" "$VENDOR/mermaid"

curl -fsSL "https://registry.npmjs.org/katex/-/katex-$KATEX.tgz" -o "$TMP/katex.tgz"
tar -xzf "$TMP/katex.tgz" -C "$TMP"
cp "$TMP/package/dist/katex.min.css" "$TMP/package/dist/katex.min.js" "$VENDOR/katex/"
mkdir -p "$VENDOR/katex/contrib" "$VENDOR/katex/fonts"
cp "$TMP/package/dist/contrib/auto-render.min.js" "$VENDOR/katex/contrib/"
cp "$TMP/package/dist/fonts/"*.woff2 "$VENDOR/katex/fonts/"
cp "$TMP/package/LICENSE" "$VENDOR/katex/LICENSE"

curl -fsSL "https://cdn.jsdelivr.net/npm/mermaid@$MERMAID/dist/mermaid.min.js" -o "$VENDOR/mermaid/mermaid.min.js"
curl -fsSL "https://cdn.jsdelivr.net/npm/mermaid@$MERMAID/LICENSE" -o "$VENDOR/mermaid/LICENSE"

echo "fetched KaTeX $KATEX and Mermaid $MERMAID into $VENDOR"
