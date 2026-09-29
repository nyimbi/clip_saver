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

SOURCES=(
	"$APP/Conversation.swift"
	"$APP/Frontmatter.swift"
	"$APP/Fingerprint.swift"
	"$APP/ConversationRenderer.swift"
	"$APP/IncrementalSave.swift"
	"$APP/NativeMessage.swift"
	"$APP/BridgeHandler.swift"
	"$APP/ConversationSaver.swift"
	"$APP/SQLiteDatabase.swift"
	"$APP/ArchiveStore.swift"
	"$APP/ArchiveIndexer.swift"
	"$APP/ContentTagger.swift"
	"$APP/SearchService.swift"
	"$APP/FilenameGenerator.swift"
	"$REPO/bridge/host/main.swift"
)

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
