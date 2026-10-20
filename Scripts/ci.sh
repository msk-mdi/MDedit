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

# The crashed thread of each crash report written since a file was, with
# the exception and the last thread's queue.
crash_reports() {
	find "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports -name '*.ips' -newer "$1" 2>/dev/null | while IFS= read -r report; do
		echo "::group::Crash report $(basename "$report")"
		python3 - "$report" <<-'PYTHON'
			import json, sys
			text = open(sys.argv[1]).read()
			header, _, body = text.partition("\n")
			report = json.loads(body)
			images = report.get("usedImages", [])
			print(json.loads(header).get("name"), report.get("exception"), report.get("termination", {}).get("indicator"))
			for thread in report.get("threads", []):
			    if not thread.get("triggered"):
			        continue
			    print("crashed thread:", thread.get("name") or thread.get("queue") or thread.get("id"))
			    for frame in thread.get("frames", [])[:60]:
			        image = images[frame["imageIndex"]].get("name", "?") if frame.get("imageIndex", -1) < len(images) else "?"
			        where = frame.get("symbol", hex(frame.get("imageOffset", 0)))
			        source = f' {frame["sourceFile"]}:{frame.get("sourceLine")}' if "sourceFile" in frame else ""
			        print(f"  {image}  {where}{source}")
		PYTHON
		echo "::endgroup::"
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
		# Crash reports are looked for from here: the log itself is written
		# to until the tests end, after any crash.
		started="$(mktemp)"
		# A crash prints the crashed thread's Swift backtrace in the log.
		SWIFT_BACKTRACE='enable=yes,interactive=no,threads=crashed' swift test 2>&1 | tee "$LOG"
		status=${PIPESTATUS[0]}
		annotate error '^[^ ].*:[0-9]+:[0-9]+: error: |recorded an issue at |Terminating app due to|Fatal error'
		# A crash of the test process leaves no test to blame; macOS's crash
		# report says where it was. It is written some seconds after the crash.
		if [ "$status" -ne 0 ]; then
			if grep -q 'exited with unexpected signal' "$LOG"; then sleep 20; fi
			crash_reports "$started"
		fi
		exit "$status"
		;;
	*)
		echo "usage: $0 toolchain|build|test" >&2
		exit 2
		;;
esac
