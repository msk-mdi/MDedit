#!/bin/bash
# Lints with swift-format, using the rules in .swift-format.
#
# Layout findings (indentation, line breaks, spacing, line length, trailing
# commas) are left out: the code lays out keyword tables, palettes and
# embedded CSS and JavaScript by hand, and the pretty-printer would reflow
# them. Everything else fails the lint.
# Usage: Scripts/lint.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LAYOUT='\[(Indentation|AddLines|RemoveLine|Spacing|LineLength|TrailingComma)\]'
findings="$(swift format lint --recursive --parallel Sources Tests Package.swift 2>&1 \
	| grep -E 'warning:|error:' | grep -Ev "$LAYOUT" || true)"

if [ -n "$findings" ]; then
	echo "$findings"
	echo "lint: $(echo "$findings" | wc -l | tr -d ' ') finding(s)"
	exit 1
fi
echo "lint: clean"
