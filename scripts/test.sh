#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

MIN_TESTS="${MIN_TESTS:-150}"
DERIVED="${DERIVED:-$(mktemp -d)}"

xcodebuild \
	-project Clipboard_saver.xcodeproj \
	-scheme Clipboard_saver \
	-destination 'platform=macOS' \
	-derivedDataPath "$DERIVED" \
	test >"$DERIVED/test.log" 2>&1 || {
		rg -n "error:|failed|\*\* TEST" "$DERIVED/test.log" | head -40 || true
		echo "test run failed; full log: $DERIVED/test.log" >&2
		exit 1
	}

RESULT="$(ls -td "$DERIVED"/Logs/Test/*.xcresult | head -1)"
SUMMARY="$(xcrun xcresulttool get test-results summary --path "$RESULT")"

read -r TOTAL PASSED FAILED SKIPPED < <(python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
print(
    d.get("totalTestCount", 0),
    d.get("passedTests", 0),
    d.get("failedTests", 0),
    d.get("skippedTests", 0),
)
' <<<"$SUMMARY")

echo "tests total=$TOTAL passed=$PASSED failed=$FAILED skipped=$SKIPPED (floor $MIN_TESTS)"

if [ "$TOTAL" -eq 0 ]; then
	echo "vacuous pass: 0 tests executed — the scheme is not wired to a test target" >&2
	exit 1
fi

if [ "$TOTAL" -lt "$MIN_TESTS" ]; then
	echo "test count $TOTAL is below floor $MIN_TESTS — a target is likely unwired" >&2
	exit 1
fi

# The bridge.
#
# This used to be Swift only, which is how three separate defects reached `main`
# with every test green: a hand-maintained source list in the host build script
# drifted by seven files and the binary stopped compiling; the extension never
# sent a field the model required, so every real save was refused; and the
# selection path dropped a third of each turn. None of them is visible from one
# language, so a gate that runs one language cannot see any of them.
if [ "${BRIDGE:-1}" = "1" ]; then
	command -v node >/dev/null || { echo "node is required for the bridge tests" >&2; exit 1; }
	[ -d bridge/node_modules ] || {
		echo "bridge/node_modules is missing -- run: (cd bridge && npm install)" >&2
		exit 1
	}

	echo "--- bridge unit tests"
	(cd bridge && node --test test/)

	echo "--- assemble the extension"
	# Built, not just tested. The packaged files are the ones Chrome runs, and
	# until something loaded them, an extension that could not load at all passed
	# every test in the repository.
	(cd bridge && node build.mjs)

	echo "--- host build"
	# Built, not just tested: a stale or unbuildable host passes every unit test
	# in the repository.
	./bridge/host/build.sh "${DERIVED}/clipboard-saver-host" >"$DERIVED/host-build.log" 2>&1 || {
		rg -n "error:" "$DERIVED/host-build.log" | head -20 || true
		echo "host build failed; full log: $DERIVED/host-build.log" >&2
		exit 1
	}

	echo "--- end to end"
	# Extension source -> native framing -> compiled host -> the saved file.
	# The payload comes out of the real extractor, so this cannot drift from what
	# the extension actually sends.
	mkdir -p "$DERIVED/e2e"
	(cd bridge && node e2e-host.mjs "$DERIVED/clipboard-saver-host" "$DERIVED/e2e")

	# Chrome's own packer, when Chrome is installed.
	#
	# It is the only validator that knows the rules a real store enforces, and it
	# found one no test here would have: a keyboard shortcut written as
	# "Command+Shift+S" instead of "Ctrl+Shift+S", which Chrome rejects outright
	# and which every other check here considered fine.
	CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
	if [ -x "$CHROME" ]; then
		echo "--- chrome pack"
		rm -rf "$DERIVED/pack" && mkdir -p "$DERIVED/pack"
		cp -R bridge/extension "$DERIVED/pack/ext"
		"$CHROME" --no-first-run --user-data-dir="$DERIVED/pack/profile" \
			--pack-extension="$DERIVED/pack/ext" >"$DERIVED/pack.log" 2>&1 || true
		# Chrome reports manifest problems on stderr and still exits 0, so the
		# only reliable check is whether it produced a package at all.
		if [ ! -f "$DERIVED/pack/ext.crx" ]; then
			rg -i "error|invalid" "$DERIVED/pack.log" | head -10 || true
			echo "chrome refused to package the extension; log: $DERIVED/pack.log" >&2
			exit 1
		fi
		echo "chrome packaged the extension"
	else
		echo "--- chrome pack (skipped: no Chrome)"
	fi
fi

echo "ok"
