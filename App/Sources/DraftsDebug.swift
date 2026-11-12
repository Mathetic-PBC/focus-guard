#if DEBUG
import AppKit
import FocusGuardCore

/// Drives the composer the way a person would, for a scripted run that can't
/// type or click. Each command goes through the same entry point a real key
/// or paste does. Compiled out of release builds.
@MainActor
enum DraftsDebug {
    static func run(_ command: String) {
        let composer = ComposerModel.shared
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "compose-type":
            guard let textView = composer.textView else { return Log.write("debug: no text view") }
            textView.insertText(argument, replacementRange: textView.selectedRange())
        case "compose-caret":
            guard let textView = composer.textView, let location = Int(argument) else { return }
            textView.setSelectedRange(NSRange(location: location, length: 0))
        case "compose-key":
            guard let textView = composer.textView else { return }
            let selectors: [String: Selector] = [
                "down": #selector(NSResponder.moveDown(_:)), "up": #selector(NSResponder.moveUp(_:)),
                "return": #selector(NSResponder.insertNewline(_:)), "tab": #selector(NSResponder.insertTab(_:)),
                "esc": #selector(NSResponder.cancelOperation(_:)),
            ]
            if let selector = selectors[argument] { textView.doCommand(by: selector) }
        case "compose-image":
            composer.add(files: [URL(fileURLWithPath: argument)], data: nil)
        case "compose-clipboard":
            // An image copied as data, as a screenshot is, on a pasteboard of
            // its own so the real clipboard is left alone.
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.mathetic.FocusGuard.test"))
            pasteboard.clearContents()
            if let data = try? Data(contentsOf: URL(fileURLWithPath: argument)) { pasteboard.setData(data, forType: .png) }
            let found = DraftMedia.images(on: pasteboard)
            composer.add(files: found.files, data: found.data)
        case "compose-save":
            composer.save()
        case "compose-edit-first":
            if let draft = DraftsModel.shared.book.drafts.first { composer.load(draft) }
        case "compose-copy-first":
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.mathetic.FocusGuard.test"))
            if let draft = DraftsModel.shared.book.drafts.first {
                DraftMedia.copy(draft.images, to: pasteboard)
                let back = DraftMedia.images(on: pasteboard)
                Log.write("debug: copied \(draft.images.count) image(s), a paste would receive \(back.files.count) file(s)")
            }
        case "compose-state":
            Log.write("debug: text=\(composer.text.debugDescription) images=\(composer.images.count) offered=\(composer.suggestions.map(\.handle)) selected=\(composer.selected) unmatched=\(composer.unmatched ?? "-")")
        case "people-import":
            DraftsModel.shared.importPeople()
        default:
            Log.write("debug: unknown \(command)")
        }
    }
}
#endif
