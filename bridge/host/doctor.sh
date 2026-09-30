#!/bin/bash
#
# Checks the whole chain and says which link is broken.
#
# Four things have to line up before a save can work, and from the extension's
# side every one of them looks identical: the port opens and closes with nothing
# on it, and the user is told "The Clipboard Saver app does not appear to be
# installed". That message is true in all four cases and useful in none.
#
#   1. The extension is assembled.      extension/lib/ has to exist and be current.
#   2. The host binary is where the manifest says, and is executable.
#   3. The manifest is where the browser reads it from.
#   4. The manifest's allowed_origins names the loaded extension's real ID.
#
# Read-only: this changes nothing, so it is safe to run at any time.
#
#   ./bridge/host/doctor.sh

set -uo pipefail

cd "$(dirname "$0")/../.."
REPO="$PWD"

APP_BUNDLE="/Applications/Clipboard_saver.app"
HOST_IN_BUNDLE="$APP_BUNDLE/Contents/MacOS/clipboard-saver-host"
MANIFEST_NAME="datacraft.Clipboard_saver.json"

pass=0
warn=0
fail=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
note() { printf '  \033[33mwarn\033[0m  %s\n' "$1"; warn=$((warn + 1)); }

echo
echo "1. the app"
if [ -d "$APP_BUNDLE" ]; then
	ok "$APP_BUNDLE is installed"
else
	bad "$APP_BUNDLE is not installed -- build and install the app first"
fi

echo
echo "2. the extension is assembled"
# A Chrome extension is a sealed root and an MV3 content script is a classic
# script, so the sources in bridge/extension cannot be loaded as they stand.
# `extension/lib/` is what the manifest points at, and it is generated.
if [ -f "$REPO/bridge/extension/lib/content.js" ] && [ -f "$REPO/bridge/extension/lib/background.js" ]; then
	if (cd bridge && node build.mjs --check) >/dev/null 2>&1; then
		ok "extension/lib is built and current"
	else
		note "extension/lib is out of date -- run: (cd bridge && node build.mjs)"
	fi
else
	bad "extension/lib is missing -- run: (cd bridge && node build.mjs)"
fi

echo
echo "3. the host binary"
if [ -x "$HOST_IN_BUNDLE" ]; then
	ok "$HOST_IN_BUNDLE is installed and executable"
elif [ -x "$REPO/bridge/host/build/clipboard-saver-host" ]; then
	bad "the host is built but not installed -- run: ./bridge/host/install.sh"
else
	bad "the host is not built -- run: ./bridge/host/build.sh"
fi

echo
echo "4. the native messaging manifest"
# Every browser reads a different directory, and a manifest in one of them says
# nothing about the others.
checked_any=0
for dir in \
	"$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts" \
	"$HOME/Library/Application Support/Chromium/NativeMessagingHosts" \
	"$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts" \
	"$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts" \
	"$HOME/Library/Application Support/Mozilla/NativeMessagingHosts"
do
	[ -d "$(dirname "$dir")" ] || continue
	checked_any=1
	file="$dir/$MANIFEST_NAME"
	if [ ! -f "$file" ]; then
		note "$(basename "$(dirname "$dir")") -- no manifest at $file"
		continue
	fi

	path_at="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("path",""))' "$file" 2>/dev/null)"
	origin_at="$(python3 -c 'import json,sys; o=json.load(open(sys.argv[1])).get("allowed_origins",[""]); print(o[0] if o else "")' "$file" 2>/dev/null)"

	if [ ! -x "$path_at" ]; then
		bad "$(basename "$(dirname "$dir")") -- the manifest points at $path_at, which is not an executable file"
		continue
	fi

	id="${origin_at#chrome-extension://}"
	id="${id%/}"

	# A placeholder passes the shape check -- 'a' is inside 'a-p' -- and it is
	# what gets written when nobody has the real id to hand. Chrome rejects it
	# with "forbidden", which the extension reports as the app not being
	# installed.
	if printf '%s' "$id" | grep -Eq '^(.)\1{31}$'; then
		bad "$(basename "$(dirname "$dir")") -- the manifest allows the placeholder id $id, which no extension has"
	elif ! printf '%s' "$id" | grep -Eq '^[a-p]{32}$'; then
		bad "$(basename "$(dirname "$dir")") -- allowed_origins holds '$origin_at', which is not an extension id"
	else
		ok "$(basename "$(dirname "$dir")") -- allows $id"
	fi
done
[ "$checked_any" -eq 0 ] && bad "no supported browser was found on this machine"

echo
echo "5. what the browser thinks of the extension"
# Only readable once the extension has been loaded at least once, and it is the
# one check that can see a manifest Chrome accepted and then disabled.
PROFILE="$HOME/Library/Application Support/Google/Chrome/Default/Preferences"
if [ -f "$PROFILE" ]; then
	python3 - "$PROFILE" "$REPO/bridge/extension" <<'PY' || true
import json, pathlib, sys
try:
    d = json.loads(pathlib.Path(sys.argv[1]).read_text())
except Exception:
    raise SystemExit
target = str(pathlib.Path(sys.argv[2]).resolve())
settings = d.get("extensions", {}).get("settings", {})
if not settings:
    print("  warn  Chrome's profile lists no extensions -- has this one been loaded?")
for eid, meta in settings.items():
    if str(meta.get("path", "")) == target:
        state = meta.get("state")
        errors = meta.get("manifest_errors") or meta.get("install_warnings") or []
        if state == 1:
            print(f"  ok    Chrome has {eid} enabled")
        else:
            print(f"  FAIL  Chrome has {eid} in state {state} (1 is enabled)")
        for e in errors:
            print(f"  FAIL  manifest: {e}")
        break
else:
    if settings:
        print("  warn  this extension is not in Chrome's profile -- load it in chrome://extensions")
PY
else
	note "no Chrome profile at $PROFILE -- skip"
fi

echo
echo "-------------------------------------------------------------"
printf 'passed %d, warnings %d, failures %d\n' "$pass" "$warn" "$fail"
echo

if [ "$fail" -gt 0 ]; then
	echo "Something above is why a save does nothing. Fix it in order -- each step"
	echo "depends on the one before it."
	exit 1
fi

if [ "$warn" -gt 0 ]; then
	echo "No hard failures. Warnings are worth reading, but the chain is intact."
	exit 0
fi

echo "The chain is intact. A save that still fails is a problem the app reported;"
echo "the extension shows it as a badge and a toast, and the reason is in"
	echo "chrome://extensions -> the extension -> Errors."
