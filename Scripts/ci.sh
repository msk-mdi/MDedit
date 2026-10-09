#!/bin/bash
# CI steps, for GitHub Actions: Scripts/ci.sh toolchain|build|test
#
# Compiler errors and test failures are reported as workflow annotations, so
# they show on the run's page and through the API without opening the logs
# (which GitHub only shows to signed-in users).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
LOG="$(mktemp)"

# Paths in annotations are relative to the checkout.
annotate() {
	local level="$1" pattern="$2"
	# Without the colour codes swift puts around "error:".
	sed -E $'s/\x1b\\[[0-9;]*m//g' "$LOG" | grep -E "$pattern" | sed -E "s#^$ROOT/##" | sort -u | head -40 | while IFS= read -r line; do
		if [[ "$line" =~ ^([^:]+):([0-9]+):([0-9]+):\ (error|warning):\ (.*)$ ]]; then
			echo "::$level file=${BASH_REMATCH[1]},line=${BASH_REMATCH[2]},col=${BASH_REMATCH[3]}::${BASH_REMATCH[5]}"
		else
			echo "::$level::$line"
		fi
	done
}

case "${1:-}" in
	toolchain)
		# The newest Xcode on the runner, which is not always its default.
		newest="$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1)"
		if [ -n "$newest" ]; then sudo xcode-select -s "$newest"; fi
		echo "::notice::$(xcodebuild -version | tr '\n' ' ')· $(swift --version 2>&1 | head -1) · SDK $(xcrun --show-sdk-version) · Xcodes: $(ls -d /Applications/Xcode*.app | xargs -n1 basename | tr '\n' ' ')"
		;;
	build)
		swift build 2>&1 | tee "$LOG"
		status=${PIPESTATUS[0]}
		annotate error '^[^ ].*:[0-9]+:[0-9]+: error: '
		exit "$status"
		;;
	test)
		swift test 2>&1 | tee "$LOG"
		status=${PIPESTATUS[0]}
		annotate error '^[^ ].*:[0-9]+:[0-9]+: error: |recorded an issue at |Terminating app due to|Fatal error'
		exit "$status"
		;;
	*)
		echo "usage: $0 toolchain|build|test" >&2
		exit 2
		;;
esac
