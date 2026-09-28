import AppKit
import ServiceManagement
import SwiftUI

@main
struct Clipboard_saverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The app exists only to serve the Services menu, so there is no
        // window and no menu bar. `LSUIElement` in Info.plist keeps it out of
        // the Dock.
        Settings {
            EmptyView()
        }
    }
}

enum SaveOutcome {
    case written([URL])
    case cancelled
    case failed(String)
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        registerAtLoginIfNeeded()
    }

    /// Finder only lists this app's services while the provider process is
    /// running. Nothing else launches a Services-only app, so after a reboot
    /// the context menu simply does not offer the service and the tool looks
    /// broken until the user opens it by hand. Registering as a login item
    /// makes the provider present on every session.
    ///
    /// This is a no-op once the OS reports the item as enabled, so it does not
    /// prompt repeatedly.
    private func registerAtLoginIfNeeded() {
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            // Registration can legitimately fail (managed device, user
            // declined). The app still works when it is running, so this is not
            // worth interrupting the user over.
            NSLog("Clipboard Saver could not register as a login item: \(error.localizedDescription)")
        }
    }

    // MARK: - Services

    /// "Save Clipboard to File" — the Services menu of any application.
    @objc func run(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let desktop = desktopDirectory() else {
            return finish(.failed("Could not locate the Desktop directory."), reveal: false, error)
        }
        saveInteractively(pasteboard: pasteboard, into: [desktop], reveal: false, error)
    }

    /// "Save Clipboard as Markdown" — right-clicked folder(s) or file(s).
    ///
    /// Finder only offers this one when the pasteboard actually carries file
    /// URLs, so it is the service for right-clicking something. The
    /// front-window fallback below covers the case where it is somehow invoked
    /// without one.
    @objc func saveToFolder(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let folders = resolveDestinations(from: pasteboard, frontWindowFolder: frontFinderDirectory())
        guard !folders.isEmpty else {
            return finish(
                .failed("Could not determine which folder to save into. Open a Finder window first."),
                reveal: false, error
            )
        }
        // Clipboard content comes from the general pasteboard; the selection
        // pasteboard only carries the file URLs.
        saveInteractively(pasteboard: .general, into: folders, reveal: true, error)
    }

    /// "Save Clipboard as Markdown Here" — right-clicked the Finder
    /// background.
    ///
    /// This one carries no `NSSendTypes`, so Finder offers it unconditionally.
    /// That matters: on a background right-click the pasteboard has no file
    /// URL, so `saveToFolder` is not offered at all and this is the only way to
    /// save into the current folder. The two are not duplicates.
    @objc func saveHere(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let folder = frontFinderDirectory() else {
            return finish(
                .failed("Could not determine the Finder folder. Open a Finder window first."),
                reveal: false, error
            )
        }
        saveInteractively(pasteboard: .general, into: [folder], reveal: true, error)
    }

    /// Where a save should land.
    ///
    /// Prefers what was selected — a right-clicked folder is used directly, a
    /// right-clicked file contributes its parent. Falls back to the folder shown
    /// in the front Finder window.
    func resolveDestinations(from pasteboard: NSPasteboard, frontWindowFolder: URL?) -> [URL] {
        let selected = destinationFolders(from: pasteboard)
        if !selected.isEmpty { return selected }
        guard let frontWindowFolder else { return [] }
        return [frontWindowFolder]
    }

    // MARK: - Interactive entry point

    /// Reads the clipboard, asks for a filename, then writes.
    ///
    /// The filename is offered pre-filled with the document's own title and
    /// stays fully editable. A save panel is modal here on purpose: the process
    /// terminates as soon as the service returns, so an asynchronous panel
    /// would be killed before the user could answer it.
    private func saveInteractively(
        pasteboard: NSPasteboard,
        into directories: [URL],
        reveal: Bool,
        _ error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let export = MarkdownExporter.export(from: pasteboard) else {
            return finish(.failed("The clipboard holds no text."), reveal: false, error)
        }
        guard let first = directories.first else {
            return finish(.failed("Could not determine where to save."), reveal: false, error)
        }

        let suggested = FilenameGenerator.make(
            from: export.text,
            fileExtension: export.source.fileExtension,
            in: first
        )
        guard let chosen = askForFilename(suggesting: suggested, in: first) else {
            // Cancelling is not an error: no alert, no file.
            return finish(.cancelled, reveal: false, error)
        }

        finish(save(export: export, into: directories, name: chosen), reveal: reveal, error)
    }

    /// Shows a save panel seeded with `suggested` in `directory`. Returns the
    /// sanitised name, or `nil` when the user cancels.
    private func askForFilename(suggesting suggested: String, in directory: URL) -> String? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggested
        panel.directoryURL = directory
        panel.title = "Save Clipboard as Markdown"
        panel.prompt = "Save"
        panel.message = "Choose a name for the clipboard contents."

        guard panel.runModal() == .OK else { return nil }

        // The user may type anything, including a path separator, so the name
        // is sanitised again. An extension is restored when the field is left
        // without one, and a new extension the user typed is respected.
        let typed = panel.nameFieldStringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .sanitizedForTypedFilename
        guard !typed.isEmpty else { return nil }

        let fallback = (suggested as NSString).pathExtension
        let extensionName = (typed as NSString).pathExtension.isEmpty ? fallback : (typed as NSString).pathExtension
        let stem = (typed as NSString).deletingPathExtension
        guard !stem.isEmpty else { return nil }
        return extensionName.isEmpty ? stem : "\(stem).\(extensionName)"
    }

    // MARK: - Pipeline

    /// Writes one file per destination directory. Returns an outcome rather
    /// than terminating, so the pipeline is testable.
    ///
    /// - Parameter name: the filename to use. The first directory receives it
    ///   verbatim, because the save panel already asked the user to confirm any
    ///   replacement. Every additional directory gets collision resolution, so
    ///   a multi-folder save never silently overwrites a second file.
    func save(export: (text: String, source: MarkdownSource), into directories: [URL], name: String) -> SaveOutcome {
        var written: [URL] = []
        var failures: [String] = []

        for (index, directory) in directories.enumerated() {
            let target = index == 0 ? name : FilenameGenerator.resolveCollision(name, in: directory)
            do {
                written.append(try write(export: export, name: target, to: directory))
            } catch {
                failures.append("\(directory.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if failures.isEmpty { return .written(written) }
        return .failed("Could not save:\n" + failures.joined(separator: "\n"))
    }

    /// Derives the filename from the document, then writes to every
    /// destination. Never overwrites.
    func save(pasteboard: NSPasteboard, into directories: [URL]) -> SaveOutcome {
        guard let export = MarkdownExporter.export(from: pasteboard) else {
            return .failed("The clipboard holds no text.")
        }
        var written: [URL] = []
        var failures: [String] = []

        for directory in directories {
            do {
                let name = FilenameGenerator.make(
                    from: export.text,
                    fileExtension: export.source.fileExtension,
                    in: directory
                )
                written.append(try write(export: export, name: name, to: directory))
            } catch {
                failures.append("\(directory.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if failures.isEmpty { return .written(written) }
        return .failed("Could not save:\n" + failures.joined(separator: "\n"))
    }

    // MARK: - Writing

    private func write(
        export: (text: String, source: MarkdownSource),
        name: String,
        to directory: URL
    ) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw NSError(
                domain: "ClipboardSaver",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(directory.path) is not a folder."]
            )
        }

        let fileURL = directory.appendingPathComponent(name)
        try export.text.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    // MARK: - Locations

    private func desktopDirectory() -> URL? {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    }

    /// Folders the service should write into. A selected folder is used
    /// directly; a selected file contributes its parent, so right-clicking a
    /// document drops the new file alongside it.
    func destinationFolders(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []

        let modern = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []

        if !modern.isEmpty {
            urls = modern
        } else if let paths = pasteboard.propertyList(
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ) as? [String] {
            // Fallback for writers that predate `public.file-url`. The type
            // cannot be synthesised, so this branch has no direct test.
            urls = paths.map { URL(fileURLWithPath: $0) }
        }

        var seen = Set<String>()
        return urls.compactMap { url in
            var isDirectory: ObjCBool = false
            let folder = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue ? url : url.deletingLastPathComponent()
            // Selecting a file and its parent folder must not write twice.
            return seen.insert(folder.standardizedFileURL.path).inserted ? folder : nil
        }
    }

    /// The folder shown in the front Finder window.
    private func frontFinderDirectory() -> URL? {
        let script = NSAppleScript(source: """
            tell application "Finder"
                if (count of Finder windows) is 0 then return ""
                return POSIX path of (target of front Finder window as alias)
            end tell
            """)
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        guard error == nil, let path = result?.stringValue, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Reporting

    /// A non-nil `error` makes macOS show the message; a nil one lets the
    /// service complete silently.
    private func finish(
        _ outcome: SaveOutcome,
        reveal: Bool,
        _ error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        switch outcome {
        case .written(let urls):
            if reveal, let first = urls.first {
                NSWorkspace.shared.activateFileViewerSelecting([first])
            }
        case .cancelled:
            break
        case .failed(let message):
            error.pointee = message as NSString
        }
        NSApp.terminate(nil)
    }
}
