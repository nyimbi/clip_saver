#!/bin/bash
#
# Builds the native messaging host.
#
# A `swiftc` build over the app's own sources rather than an Xcode target: the
# project uses objectVersion 77 synchronized folder groups, and adding a target
# to that by hand is a poor trade for a single-file executable with no
# resources. Sharing the sources is also the point -- the host and the app must
# agree on the wire format, the fingerprint, and the incremental-save rules, and
# there is no way for them to disagree if they are the same code.

set -euo pipefail

cd "$(dirname "$0")/../.."
REPO="$PWD"
APP="$REPO/Clipboard_saver"
OUT="${1:-$REPO/bridge/host/build/clipboard-saver-host}"

# Every app source except the SwiftUI entry point.
#
# This list used to be written out by hand, and it drifted: seven files were
# added to the app over time and never added here, so the host stopped
# compiling entirely the moment the renderer started using HTMLToMarkdown.
#
# Nothing caught it. The Xcode project uses a synchronized folder group, so it
# globs the directory and always built; and the Swift tests build through Xcode
# too. Only `build.sh` was reading a stale copy, and only a real host build
# exercised it -- so the binary that talks to the browser was broken while every
# test in the repository passed.
#
# Deriving the list means a new file is included by existing rather than by
# remembering.
EXCLUDED=(Clipboard_saverApp.swift)

SOURCES=()
for source in "$APP"/*.swift; do
	name="$(basename "$source")"
	skip=0
	for excluded in "${EXCLUDED[@]}"; do
		[ "$name" = "$excluded" ] && skip=1
	done
	[ "$skip" -eq 1 ] && continue
	SOURCES+=("$source")
done
SOURCES+=("$REPO/bridge/host/main.swift")

# A source list that silently shrinks is how the last drift stayed invisible.
if [ "${#SOURCES[@]}" -lt 16 ]; then
	echo "only ${#SOURCES[@]} sources found; expected the whole app directory" >&2
	exit 1
fi

for source in "${SOURCES[@]}"; do
	if [ ! -f "$source" ]; then
		echo "missing source: $source" >&2
		exit 1
	fi
done

mkdir -p "$(dirname "$OUT")"
swiftc -O \
	-swift-version 5 \
	-target "$(uname -m)-apple-macosx15.5" \
	-o "$OUT" \
	"${SOURCES[@]}"

echo "built $OUT"
"$OUT" --version 2>/dev/null || true
