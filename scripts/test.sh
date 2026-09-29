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

echo "ok"
