#!/bin/bash
#
# Installs the native messaging host and its manifest.
#
# Three things have to line up, and the failure mode of getting any of them wrong
# is the same unhelpful message in the extension -- "The Clipboard Saver app does
# not appear to be installed" -- for three quite different reasons:
#
#   1. The host binary has to exist at the path the manifest names.
#   2. The manifest has to exist where the *browser* looks for it, which is
#      per-browser and not the app's own directory.
#   3. The manifest's `allowed_origins` has to name the extension's actual ID,
#      which does not exist until the extension is loaded.

set -euo pipefail

cd "$(dirname "$0")/../.."
REPO="$PWD"

HOST_SRC="$REPO/bridge/host/build/clipboard-saver-host"
APP_BUNDLE="/Applications/Clipboard_saver.app"
# The host binary, NOT the app. The manifest's `path` is what the browser
# launches; pointing it at the app would start an LSUIElement agent that never
# reads stdin, and the extension would report the app as not installed. The
# entire reason the host is a separate binary is that this path must not be the
# app.
HOST_IN_BUNDLE="$APP_BUNDLE/Contents/MacOS/clipboard-saver-host"
HOST_MANIFEST_PATH="$HOST_IN_BUNDLE"
TEMPLATE="$REPO/bridge/native-messaging-host.json"

if [ ! -f "$HOST_SRC" ]; then
	echo "The host is not built. Run bridge/host/build.sh first." >&2
	exit 1
fi

if [ ! -d "$APP_BUNDLE" ]; then
	echo "$APP_BUNDLE is not installed. Build and install the app first." >&2
	exit 1
fi

# The extension's ID.
#
# An unpacked extension with no `key` in its manifest has no ID of its own:
# Chrome derives one from the absolute path, as the first 32 hex digits of its
# SHA-256 mapped onto a-p. So it can be computed instead of copied.
#
# It is offered as a suggestion rather than trusted outright, because the exact
# path string Chrome hashes depends on how the folder was chosen, and a wrong
# guess writes a manifest the browser ignores -- which looks exactly like the
# app not being installed. The user confirms it against chrome://extensions, and
# anything they type wins.
derive_id() {
	printf '%s' "$1" | shasum -a 256 | cut -c1-32 | tr '0123456789abcdef' 'abcdefghijklmnop'
}

SUGGESTED_ID="$(derive_id "$(cd "$REPO/bridge/extension" && pwd -P)")"
EXTENSION_ID="${1:-${CLIPBOARD_SAVER_EXTENSION_ID:-}}"

if [ -z "$EXTENSION_ID" ]; then
	echo
	echo "Chrome gives an unpacked extension an ID derived from its folder, and for"
	echo "this folder that is:"
	echo
	echo "    $SUGGESTED_ID"
	echo
	echo "Load bridge/extension in chrome://extensions and check it matches. If it does"
	echo "not, paste the real one instead -- the browser hashes the path you chose, so"
	echo "a symlinked or relative path gives a different answer."
	read -r -p "Extension ID (leave empty to skip the manifest): " EXTENSION_ID
	EXTENSION_ID="${EXTENSION_ID:-$SUGGESTED_ID}"
fi

# 1. The binary. A copy rather than a symlink: the browser launches the path in
# the manifest, and a symlink into the repository would break the moment the
# working tree moved.
cp "$HOST_SRC" "$HOST_IN_BUNDLE"
chmod +x "$HOST_IN_BUNDLE"
echo "installed $HOST_IN_BUNDLE"

if [ -z "$EXTENSION_ID" ]; then
	echo "Skipped the manifests. Re-run with the extension ID once the extension is loaded."
	exit 0
fi

# A malformed ID here produces a manifest Chrome silently ignores, which looks
# identical to the host not existing.
if ! printf '%s' "$EXTENSION_ID" | grep -Eq '^[a-p]{32}$'; then
	echo "That does not look like an extension ID: expected 32 characters a-p." >&2
	exit 1
fi

# A placeholder passes the shape check perfectly well -- 'a' is in 'a-p', so a
# run of thirty-two a's is a syntactically valid id. And it is exactly what gets
# typed when nobody has the real one to hand, so it is called out by name rather
# than left to fail later as "the app is not installed".
if printf '%s' "$EXTENSION_ID" | grep -Eq '^(.)\1{31}$'; then
	echo "That is a placeholder, not a real ID: every character is the same." >&2
	echo "Load the extension first, then copy the real one from chrome://extensions." >&2
	exit 1
fi

ORIGIN="chrome-extension://$EXTENSION_ID/"

# 2. Where each browser looks. Chrome and Chromium read the user-level directory;
# Firefox uses a per-browser variant of the same layout.
CHROME_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
CHROMIUM_DIRS=(
	"$HOME/Library/Application Support/Chromium/NativeMessagingHosts"
	"$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts"
	"$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
)
FIREFOX_DIR="$HOME/Library/Application Support/Mozilla/NativeMessagingHosts"

write_manifest() {
	local dir="$1"
	mkdir -p "$dir"
	# Written from the template so the path and the allowed origin cannot drift
	# from the documented ones.
	sed \
		-e "s|PLACEHOLDER_PATH|$HOST_MANIFEST_PATH|" \
		-e "s|PLACEHOLDER_ORIGIN|$ORIGIN|" \
		"$TEMPLATE" >"$dir/datacraft.Clipboard_saver.json"
	echo "wrote $dir/datacraft.Clipboard_saver.json"
}

write_manifest "$CHROME_DIR"
for dir in "${CHROMIUM_DIRS[@]}"; do
	[ -d "$(dirname "$dir")" ] && write_manifest "$dir"
done
# Firefox only exists if it is installed; writing into a directory no browser
# reads would just be litter.
if [ -d "$HOME/Library/Application Support/Firefox" ]; then
	write_manifest "$FIREFOX_DIR"
fi

echo
echo "Restart the browser, then try 'Save conversation as Markdown' on a page."
echo "If it fails, run ./bridge/host/doctor.sh -- it says which of the three"
echo "things above is wrong, rather than leaving one message for all three."
