import AppKit
import FocusGuardCore
import SwiftUI
import UniformTypeIdentifiers

/// Posts written while X is blocked. They are kept in a file on this Mac and
/// never sent from here: posting means opening X's own compose page with the
/// text filled in, which is only offered once X is reachable again.
@MainActor
final class DraftsModel: ObservableObject {
    static let shared = DraftsModel()

    @Published private(set) var book: DraftBook
    /// The draft most recently deleted, so one click can bring it back.
    @Published private(set) var lastDeleted: TweetDraft?
    /// True when the window was opened because X just became reachable.
    @Published var reviewing = false
    @Published private(set) var importing = false
    @Published private(set) var importResult: String?

    private init() {
        book = DraftStore.load(from: Paths.drafts)
    }

    var count: Int { book.drafts.count }

    func save(text: String, images: [String], replacing id: String?) -> Bool {
        guard book.save(text: text, images: images, replacing: id, now: Date()) != nil else { return false }
        persist()
        return true
    }

    func delete(_ id: String) {
        lastDeleted = book.remove(id)
        persist()
    }

    func undoDelete() {
        guard let draft = lastDeleted else { return }
        book.restore(draft)
        lastDeleted = nil
        persist()
    }

    /// Opens X's compose page with the draft's text. The address can't carry
    /// images, so those are put on the clipboard to be pasted into the box.
    /// The draft is kept, marked as opened, until the person says it went out.
    func post(_ draft: TweetDraft) {
        guard let url = TweetText.composeURL(for: draft.text) else { return }
        if !draft.images.isEmpty { DraftMedia.copy(draft.images, to: .general) }
        NSWorkspace.shared.open(url)
        book.markOpened(draft.id, now: Date())
        persist()
        Log.write("drafts: opened compose page for a draft with \(draft.images.count) image(s)")
    }

    func keep(_ id: String) {
        book.markOpened(id, now: nil)
        persist()
    }

    /// Fills the people directory from browser history. Only ever started by
    /// a click on the button that says what it reads.
    func importPeople() {
        guard !importing else { return }
        importing = true
        importResult = nil
        Task.detached(priority: .userInitiated) {
            let found = PeopleImporter.run()
            await MainActor.run {
                let added = self.book.merge(found.people)
                self.persist()
                self.importing = false
                // A tag being typed when the list arrived can now be matched.
                let composer = ComposerModel.shared
                if let caret = composer.textView?.selectedRange().location { composer.refresh(caret: caret) }
                if found.sources == 0 {
                    self.importResult = "No Chrome-family browser history was found."
                } else if found.people.isEmpty {
                    self.importResult = "No X profile pages were found in your browser history."
                } else {
                    self.importResult = "Found \(found.people.count) people, \(added) of them new."
                }
                Log.write("drafts: people import read \(found.sources) history file(s), found \(found.people.count), added \(added)")
            }
        }
    }

    /// Deletes image files nothing points at. The draft that can still be
    /// brought back by Undo, and the one being written, count as pointing.
    func tidyMedia() {
        var inUse = book.imagesInUse
        inUse.formUnion(lastDeleted?.images ?? [])
        inUse.formUnion(ComposerModel.shared.images)
        DraftMedia.removeUnused(keeping: inUse)
    }

    private func persist() {
        do {
            try DraftStore.save(book, to: Paths.drafts)
        } catch {
            Log.write("drafts: save failed: \(error)")
        }
    }
}

struct DraftsView: View {
    @EnvironmentObject private var session: SessionController
    @ObservedObject private var model = DraftsModel.shared
    @ObservedObject private var composer = ComposerModel.shared
    @State private var confirmingImport = false

    private var blocked: Bool { session.isXBlocked }
    private var reviewFirst: Bool { model.reviewing && !blocked && model.count > 0 && composer.editing == nil }

    var body: some View {
        VStack(spacing: 0) {
            banner
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Coming back to post, the drafts lead. Otherwise the
                    // window is for writing, and the box does.
                    if !reviewFirst { composerSection }
                    if let deleted = model.lastDeleted {
                        HStack {
                            Text("Deleted “\(deleted.text.prefix(40))\(deleted.text.count > 40 ? "…" : "")”")
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Undo") { model.undoDelete() }
                        }
                        .font(.callout)
                    }
                    list
                    if reviewFirst { composerSection }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 540, minHeight: 500)
        .onAppear {
            model.tidyMedia()
            if !model.reviewing { composer.textView?.window?.makeFirstResponder(composer.textView) }
        }
        .confirmationDialog(
            "Import people from your browser history?", isPresented: $confirmingImport, titleVisibility: .visible
        ) {
            Button("Import") { model.importPeople() }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Focus Guard reads the address and title of X profile pages in the history of Chrome and browsers built on it, on this Mac, to learn names and handles. Nothing else is read and nothing leaves the Mac.")
        }
    }

    // MARK: Banner

    private var banner: some View {
        HStack(spacing: 10) {
            Image(systemName: blocked ? "lock.fill" : "paperplane.fill")
                .foregroundStyle(blocked ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(bannerTitle).font(.headline)
                Text(bannerDetail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var bannerTitle: String {
        if blocked { return "X is blocked while \(session.activeProfile?.name ?? "your Focus") is on" }
        if model.reviewing, model.count > 0 {
            return model.count == 1 ? "X is unblocked. You have 1 draft" : "X is unblocked. You have \(model.count) drafts"
        }
        return "X is not blocked"
    }

    private var bannerDetail: String {
        if blocked { return "Write here. Drafts are saved on this Mac and can be posted when the session ends." }
        if model.count == 0 { return "Drafts you write here stay on this Mac until you post them." }
        return "Post opens X with the text filled in. Nothing is sent until you press Post there."
    }

    // MARK: Composer

    private var composerSection: some View {
        let length = TweetText.length(of: composer.text)
        // A tag still being chosen from the list isn't counted as tagged yet.
        let choosing = composer.suggestions.isEmpty ? nil : TweetText.mentionBeingTyped(
            in: composer.text, caret: composer.textView?.selectedRange().location ?? 0)?.partial
        let mentions = TweetText.mentions(in: composer.text).filter { $0 != choosing }
        let links = TweetText.links(in: composer.text)

        return VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                ComposerEditor(model: composer)
                    .frame(minHeight: 96, maxHeight: 180)
                    .overlay(alignment: .topLeading) {
                        if composer.text.isEmpty {
                            Text("What's on your mind? Type @ to tag someone.")
                                .font(.system(size: 15))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 11)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                    }
                if !composer.images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(composer.images, id: \.self) { name in
                                Thumbnail(name: name, side: 76) { composer.remove(image: name) }
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .onDrop(of: [.fileURL], isTargeted: nil, perform: drop)

            if !composer.suggestions.isEmpty {
                SuggestionList(composer: composer)
            } else if let unmatched = composer.unmatched {
                HStack(spacing: 6) {
                    Text("No one on your people list matches “\(unmatched)”. It will be tagged as typed.")
                        .foregroundStyle(.secondary)
                    if model.book.people.count < 20 {
                        Button("Import People…") { confirmingImport = true }
                            .buttonStyle(.link)
                    }
                }
                .font(.caption)
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Menu {
                    Button("Choose Images…", action: chooseImages)
                    Button("Paste Image from Clipboard") { composer.pasteImage() }
                } label: {
                    Label("Image", systemImage: "photo")
                }
                .fixedSize()
                .disabled(composer.images.count >= TweetDraft.imageLimit)
                .help("Attach up to \(TweetDraft.imageLimit) images. You can also drop or paste them into the box.")

                Spacer()
                Text("\(length) / \(TweetText.limit)")
                    .monospacedDigit()
                    .foregroundStyle(length > TweetText.limit ? Color.red : Color.secondary)
                    .accessibilityLabel("\(length) of \(TweetText.limit) characters")
                if composer.editing != nil {
                    Button("Cancel") { composer.reset() }
                }
                Button(composer.editing == nil ? "Save Draft" : "Save Changes") { composer.save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(composer.isEmpty)
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: 3) {
                if !mentions.isEmpty {
                    Text("Tagging \(mentions.map { "@\($0)" }.formatted(.list(type: .and)))")
                }
                if !links.isEmpty {
                    Text(links.count == 1 ? "1 link, counted as 23 characters" : "\(links.count) links, counted as 23 characters each")
                }
                if length > TweetText.limit {
                    Text("Over the standard limit by \(length - TweetText.limit). X will only take it on an account with longer posts.")
                }
                if let notice = composer.notice {
                    Text(notice).foregroundStyle(.primary)
                }
                peopleLine
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var peopleLine: some View {
        HStack(spacing: 6) {
            if model.importing {
                ProgressView().controlSize(.mini)
                Text("Reading browser history…")
            } else {
                Text(model.importResult ?? peopleSummary)
                Button(model.book.people.isEmpty ? "Import People…" : "Update…") { confirmingImport = true }
                    .buttonStyle(.link)
            }
        }
    }

    private var peopleSummary: String {
        let count = model.book.people.count
        switch count {
        case 0: return "Your people list is empty, so tags can't be completed yet."
        case 1: return "1 person on your list for tagging."
        default: return "\(count.formatted()) people on your list for tagging."
        }
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        composer.add(files: panel.urls, data: nil)
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return }
                Task { @MainActor in composer.add(files: [url], data: nil) }
            }
        }
        return accepted
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if model.book.drafts.isEmpty {
            Text("No drafts yet.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 24)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.count == 1 ? "1 draft" : "\(model.count) drafts")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(model.book.drafts) { draft in
                    DraftRow(draft: draft, blocked: blocked, isBeingEdited: composer.editing == draft.id) {
                        composer.load(draft)
                        composer.textView?.window?.makeFirstResponder(composer.textView)
                    }
                }
            }
        }
    }
}

/// The people offered while a tag is typed: name over handle, as X shows
/// them, with the highlighted one taken by Return.
private struct SuggestionList: View {
    @ObservedObject var composer: ComposerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(composer.suggestions.enumerated()), id: \.element.id) { index, person in
                Button {
                    composer.accept(person)
                } label: {
                    HStack(spacing: 10) {
                        Text(initials(of: person))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(.quaternary, in: Circle())
                        VStack(alignment: .leading, spacing: 0) {
                            if let name = person.name {
                                Text(name).fontWeight(.medium).lineLimit(1)
                            }
                            Text("@\(person.handle)")
                                .foregroundStyle(person.name == nil ? .primary : .secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if index == composer.selected {
                            Text("return")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == composer.selected ? Color.accentColor.opacity(0.16) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tag \(person.name ?? person.handle), @\(person.handle)")
            }
        }
        .font(.callout)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    private func initials(of person: Person) -> String {
        let words = (person.name ?? person.handle).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "@" : letters.joined()
    }
}

/// A small square view of an attached image, with a button to take it off
/// where there is something to take it off of.
private struct Thumbnail: View {
    let name: String
    let side: CGFloat
    var onRemove: (() -> Void)?

    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(3)
                .accessibilityLabel("Remove image")
            }
        }
        .task(id: name) {
            image = NSImage(contentsOf: DraftMedia.url(for: name))
        }
        .accessibilityLabel("Attached image")
    }
}

private struct DraftRow: View {
    @ObservedObject private var model = DraftsModel.shared
    let draft: TweetDraft
    let blocked: Bool
    let isBeingEdited: Bool
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !draft.text.isEmpty {
                Text(highlighted(draft.text))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !draft.images.isEmpty {
                HStack(spacing: 8) {
                    ForEach(draft.images, id: \.self) { name in
                        Thumbnail(name: name, side: 64)
                    }
                }
            }
            if draft.openedAt != nil, !draft.images.isEmpty {
                Label(
                    draft.images.count == 1
                        ? "The image is on the clipboard. Click in X's post box and press ⌘V."
                        : "The \(draft.images.count) images are on the clipboard. Click in X's post box and press ⌘V.",
                    systemImage: "doc.on.clipboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if draft.openedAt != nil {
                    if !draft.images.isEmpty {
                        Button("Copy Images Again") { DraftMedia.copy(draft.images, to: .general) }
                    }
                    Button("Keep as Draft") { model.keep(draft.id) }
                    Button("Posted, Remove") { model.delete(draft.id) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Delete", role: .destructive) { model.delete(draft.id) }
                    Button("Edit", action: onEdit)
                        .disabled(isBeingEdited)
                    Button("Post…") { model.post(draft) }
                        .buttonStyle(.borderedProminent)
                        .disabled(blocked)
                        .help(blocked ? "X is blocked until the session ends" : "Open X with this text filled in")
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isBeingEdited ? Color.accentColor : .clear, lineWidth: 1.5))
    }

    private var status: String {
        if let opened = draft.openedAt {
            return "Opened in X \(opened.formatted(.relative(presentation: .named)))"
        }
        let written = "Written \(draft.createdAt.formatted(.relative(presentation: .named)))"
        let length = TweetText.length(of: draft.text)
        return length > TweetText.limit ? "\(written) · \(length) characters" : written
    }

    /// Tags are tinted. Links are tinted and open when clicked.
    private func highlighted(_ text: String) -> AttributedString {
        let styled = NSMutableAttributedString(string: text)
        for span in TweetText.spans(in: text) {
            let range = NSRange(location: span.location, length: span.length)
            styled.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
            if span.kind == .link, let url = URL(string: span.value) {
                styled.addAttribute(.link, value: url, range: range)
            }
        }
        return (try? AttributedString(styled, including: \.appKit)) ?? AttributedString(text)
    }
}
