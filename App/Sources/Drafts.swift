import AppKit
import FocusGuardCore
import SwiftUI

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

    private init() {
        book = DraftStore.load(from: Paths.drafts)
    }

    var count: Int { book.drafts.count }

    func save(text: String, replacing id: String?) -> Bool {
        guard book.save(text: text, replacing: id, now: Date()) != nil else { return false }
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

    /// Opens X's compose page with the draft's text. The draft is kept, marked
    /// as opened, until the person says it went out.
    func post(_ draft: TweetDraft) {
        guard let url = TweetText.composeURL(for: draft.text) else { return }
        NSWorkspace.shared.open(url)
        book.markOpened(draft.id, now: Date())
        persist()
        Log.write("drafts: opened compose page for a draft")
    }

    func keep(_ id: String) {
        book.markOpened(id, now: nil)
        persist()
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
    #if DEBUG
    /// Lets a scripted run look at the composer with something typed in it.
    static let initialText = ProcessInfo.processInfo.environment["FOCUSGUARD_DRAFT_TEXT"] ?? ""
    #else
    static let initialText = ""
    #endif

    @EnvironmentObject private var session: SessionController
    @ObservedObject private var model = DraftsModel.shared

    @State private var text = DraftsView.initialText
    @State private var editing: String?
    @FocusState private var composing: Bool

    private var blocked: Bool { session.isXBlocked }
    private var reviewFirst: Bool { model.reviewing && !blocked && model.count > 0 && editing == nil }

    var body: some View {
        VStack(spacing: 0) {
            banner
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Coming back to post, the drafts lead. Otherwise the
                    // window is for writing, and the box does.
                    if !reviewFirst { composer }
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
                    if reviewFirst { composer }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .onAppear { composing = !model.reviewing }
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

    private var composer: some View {
        let length = TweetText.length(of: text)
        let partial = TweetText.trailingMention(in: text)
        let suggestions = partial.map { model.book.suggestions(for: $0) } ?? []
        // A tag still being chosen from the suggestions isn't listed as tagged yet.
        let mentions = TweetText.mentions(in: text).filter { suggestions.isEmpty || $0 != partial }

        return VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .font(.body)
                .focused($composing)
                .frame(minHeight: 96, maxHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("What's on your mind? Type @ to tag someone.")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Draft text")

            if !suggestions.isEmpty {
                HStack(spacing: 6) {
                    Text("Tag").font(.caption).foregroundStyle(.secondary)
                    ForEach(suggestions, id: \.self) { handle in
                        Button("@\(handle)") {
                            text = TweetText.completing(text, with: handle)
                            composing = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            HStack(alignment: .firstTextBaseline) {
                if mentions.isEmpty {
                    Text("No one tagged").foregroundStyle(.tertiary)
                } else {
                    Text("Tagging \(mentions.map { "@\($0)" }.formatted(.list(type: .and)))")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text("\(length) / \(TweetText.limit)")
                    .monospacedDigit()
                    .foregroundStyle(length > TweetText.limit ? Color.red : Color.secondary)
                    .accessibilityLabel("\(length) of \(TweetText.limit) characters")
                if editing != nil {
                    Button("Cancel") {
                        editing = nil
                        text = ""
                    }
                }
                Button(editing == nil ? "Save Draft" : "Save Changes", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.callout)

            if length > TweetText.limit {
                Text("Over the standard limit by \(length - TweetText.limit). X will only take it on an account with longer posts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        if model.save(text: text, replacing: editing) {
            text = ""
            editing = nil
        }
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
                    DraftRow(draft: draft, blocked: blocked, isBeingEdited: editing == draft.id) {
                        editing = draft.id
                        text = draft.text
                        composing = true
                    }
                }
            }
        }
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
            Text(highlighted(draft.text))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if draft.openedAt != nil {
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

    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        for handle in TweetText.mentions(in: text) {
            var search = result.startIndex..<result.endIndex
            while let range = result[search].range(of: "@\(handle)", options: .caseInsensitive) {
                result[range].foregroundColor = .accentColor
                search = range.upperBound..<result.endIndex
            }
        }
        return result
    }
}
