# Loading the extension

The extension is unpacked, not packaged. There is no build step: `manifest.json`
is Manifest V3, the modules are plain ES modules, and nothing needs compiling.

## 1. Build and install the host

```sh
./bridge/host/build.sh
./bridge/host/install.sh
```

The host is a **separate binary** from the app, and has to be. Chrome launches a
native messaging host directly, on a pipe, with no GUI session; the app is an
`LSUIElement` agent whose whole purpose is to be driven by Finder. One binary
cannot be both.

`install.sh` copies the host into the app bundle and writes the native messaging
manifest into the three locations the browsers read it from. It needs the
extension ID, which does not exist until the extension is loaded.

## 2. Load the extension

- **Chrome / Brave / Edge / Arc** — `chrome://extensions`, enable Developer mode,
  "Load unpacked", choose `bridge/extension`.
- **Firefox** — `about:debugging#/runtime/this-firefox`, "Load Temporary Add-on",
  choose `bridge/extension/manifest.json`.

## 3. Finish the host installation

Re-run `install.sh` and paste the extension ID it asks for. Copy it from the
extension's card in `chrome://extensions`.

## What you can and cannot check here

The selectors in `src/adapters.js` are **unverified against live sites**. The
fixtures under `test/fixtures/` are hand-written from the structure the adapters
document, so they verify the adapters' contract — role mapping, key extraction,
ordering, title handling, and the confidence reported when a page does not match
— and nothing more. A fixture written from a guess would encode the guess and
then pass by confirming it.

To verify the selectors, open a real conversation and save the page. If a capture
comes back marked incomplete, or missing turns, that is the adapter failing and
the markup is the evidence.

## Permissions

`activeTab`, `contextMenus`, `nativeMessaging`, `storage`, `scripting`, plus host
access for the three supported sites. There is no permission for any other origin
and no network permission at all — the extension reads the page it is on and hands
it to the app. A conversation is exactly the kind of data people will not hand to
a third party, so that has to be checkable rather than claimed.
