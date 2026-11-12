import AppKit
import FocusGuardCore
import SwiftUI

/// What is being written right now: the text, its images, and the list of
/// people offered while a tag is typed.
@MainActor
final class ComposerModel: ObservableObject {
    static let shared = ComposerModel()

    @Published var text = ""
    @Published private(set) var images: [String] = []
    /// The draft being changed, when the box holds one that was saved before.
    @Published private(set) var editing: String?
    @Published private(set) var suggestions: [Person] = []
    @Published private(set) var selected = 0
    /// What was typed after "@" when nobody matched it. Shown so an unknown
    /// handle is a choice and not a surprise.
    @Published private(set) var unmatched: String?
    @Published var notice: String?

    weak var textView: NSTextView?
    private var typed: (location: Int, length: Int)?
    /// Where the caret was when the list was dismissed. The list stays away
    /// until the caret leaves that tag.
    private var dismissed: Int?

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty
    }

    // MARK: Tagging

    /// Works out who to offer, from the text and where the caret is in it.
    func refresh(caret: Int) {
        guard let found = TweetText.mentionBeingTyped(in: text, caret: caret) else {
            typed = nil
            dismissed = nil
            suggestions = []
            unmatched = nil
            return
        }
        typed = (found.location, found.length)
        if dismissed == found.location {
            suggestions = []
            unmatched = nil
            return
        }
        dismissed = nil
        let matches = DraftsModel.shared.book.suggestions(for: found.partial)
        if matches.map(\.id) != suggestions.map(\.id) { selected = 0 }
        suggestions = matches
        unmatched = matches.isEmpty && !found.partial.isEmpty ? found.partial : nil
    }

    func move(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        selected = (selected + delta + suggestions.count) % suggestions.count
    }

    /// Finishes the tag being typed as `person`, or as the highlighted one.
    func accept(_ person: Person? = nil) {
        guard let typed, let person = person ?? suggestions[safe: selected] else { return }
        let range = NSRange(location: typed.location, length: typed.length)
        // A space follows the tag, unless the text already has one there.
        let after = NSMaxRange(range)
        let source = text as NSString
        let spaced = after < source.length && source.substring(with: NSRange(location: after, length: 1)).first?.isWhitespace == true
        let replacement = spaced ? "@\(person.handle)" : "@\(person.handle) "
        if let textView, textView.shouldChangeText(in: range, replacementString: replacement) {
            textView.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(
                location: typed.location + (replacement as NSString).length + (spaced ? 1 : 0), length: 0))
        } else {
            text = (text as NSString).replacingCharacters(in: range, with: replacement)
        }
        suggestions = []
        unmatched = nil
        self.typed = nil
    }

    func dismiss() {
        dismissed = typed?.location
        suggestions = []
        unmatched = nil
    }

    // MARK: Images

    func add(files: [URL], data: Data?) {
        var names: [String] = []
        for file in files {
            if let name = DraftMedia.store(fileAt: file) { names.append(name) }
        }
        if let data, let name = DraftMedia.store(imageData: data) { names.append(name) }
        guard !names.isEmpty else {
            notice = "That isn't an image X takes."
            return
        }
        let room = TweetDraft.imageLimit - images.count
        images += names.prefix(max(0, room))
        if names.count > room {
            notice = "A post holds \(TweetDraft.imageLimit) images. The rest were left out."
        } else if let big = images.first(where: { DraftMedia.size(of: $0) > DraftMedia.sizeLimit }) {
            _ = big
            notice = "An image is over 5 MB. X may refuse it."
        } else {
            notice = nil
        }
    }

    func remove(image name: String) {
        images.removeAll { $0 == name }
        notice = nil
    }

    func pasteImage() {
        let found = DraftMedia.images(on: .general)
        if found.files.isEmpty, found.data == nil {
            notice = "There's no image on the clipboard."
        } else {
            add(files: found.files, data: found.data)
        }
    }

    // MARK: Saving

    func load(_ draft: TweetDraft) {
        editing = draft.id
        text = draft.text
        images = draft.images
        notice = nil
        suggestions = []
        unmatched = nil
    }

    func reset() {
        editing = nil
        text = ""
        images = []
        notice = nil
        suggestions = []
        unmatched = nil
    }

    func save() {
        guard DraftsModel.shared.save(text: text, images: images, replacing: editing) else { return }
        reset()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// The text box. It is an AppKit text view and not SwiftUI's editor, because
/// three things here depend on it: knowing where the caret is, so a tag can
/// be completed in the middle of a sentence; taking the arrow keys and Return
/// while the list of people is up; and receiving a pasted or dropped image.
struct ComposerEditor: NSViewRepresentable {
    @ObservedObject var model: ComposerModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        textView.delegate = context.coordinator
        textView.model = model
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = ComposerEditor.font
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.setAccessibilityLabel("Draft text")
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        scroll.documentView = textView

        model.textView = textView
        textView.string = model.text
        ComposerEditor.colour(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, textView.string != model.text else { return }
        // The text was changed from outside: cleared after a save, or loaded
        // from a draft to edit.
        textView.string = model.text
        textView.setSelectedRange(NSRange(location: (model.text as NSString).length, length: 0))
        ComposerEditor.colour(textView)
    }

    static let font = NSFont.systemFont(ofSize: 15)

    /// Tints tags and links, as X's own box does.
    static func colour(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: whole)
        for span in TweetText.spans(in: storage.string) {
            let range = NSRange(location: span.location, length: span.length)
            guard NSMaxRange(range) <= storage.length else { continue }
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
        }
        storage.endEditing()
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: ComposerModel

        init(model: ComposerModel) {
            self.model = model
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            model.text = textView.string
            ComposerEditor.colour(textView)
            model.refresh(caret: textView.selectedRange().location)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, textView.string == model.text else { return }
            model.refresh(caret: textView.selectedRange().location)
        }

        /// While the list of people is up, the keys that would move the caret
        /// or break the line drive the list instead.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !model.suggestions.isEmpty else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                model.move(1)
            case #selector(NSResponder.moveUp(_:)):
                model.move(-1)
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                model.accept()
            case #selector(NSResponder.cancelOperation(_:)):
                model.dismiss()
            default:
                return false
            }
            return true
        }
    }
}

/// A text view that turns a pasted or dropped image into an attachment and
/// pastes everything else as plain text.
final class ComposerTextView: NSTextView {
    weak var model: ComposerModel?

    override func paste(_ sender: Any?) {
        if take(from: .general) { return }
        pasteAsPlainText(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasImages(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasImages(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        take(from: sender.draggingPasteboard) || super.performDragOperation(sender)
    }

    private func hasImages(_ pasteboard: NSPasteboard) -> Bool {
        let found = DraftMedia.images(on: pasteboard)
        return !found.files.isEmpty || found.data != nil
    }

    private func take(from pasteboard: NSPasteboard) -> Bool {
        let found = DraftMedia.images(on: pasteboard)
        guard !found.files.isEmpty || found.data != nil else { return false }
        Task { @MainActor [weak model] in model?.add(files: found.files, data: found.data) }
        return true
    }
}
