import AppKit
import FocusGuardCore
import SwiftUI
import UniformTypeIdentifiers

struct ProfileEditor: View {
    @EnvironmentObject private var session: SessionController
    @Binding var profile: Profile
    let onDelete: () -> Void

    @State private var newSite = ""
    @State private var siteError: String?
    @State private var holdMessage: String?
    @State private var confirmingDelete = false

    private var locked: Bool { session.isLocked }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $profile.name, prompt: Text("Deep Focus"))
                    .disabled(locked)
            }

            connectSection
            websiteSection
            appSection

            Section {
                Stepper(value: $profile.cooldownSeconds, in: Profile.cooldownRange, step: 15) {
                    LabeledContent("Wait before blocking ends", value: formatDuration(profile.cooldownSeconds))
                }
                .disabled(locked)
            } header: {
                Text("Cool-down")
            } footer: {
                Text("Switching the Focus off starts this countdown. Blocking lasts until it finishes. Pressing Stay Focused calls it off.")
            }

            holdSection

            Section {
                Button("Delete Profile…", role: .destructive) { confirmingDelete = true }
                    .disabled(locked)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete “\(profile.name)”?", isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete Profile", role: .destructive, action: onDelete)
            Button("Keep Profile", role: .cancel) {}
        } message: {
            Text("Its lists are removed. A Focus that was connected to it stops blocking anything.")
        }
    }

    // MARK: Connect

    private var connectSection: some View {
        Section {
            LabeledContent {
                Button("Open Focus Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")!)
                }
            } label: {
                if let seen = session.lastSeen[profile.id] {
                    Label("Switched on by a Focus \(seen.formatted(.relative(presentation: .named)))",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Not connected to a Focus yet", systemImage: "circle.dashed")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Step(1, "In System Settings › Focus, choose the Focus that should use this profile.")
                Step(2, "Under Focus Filters, click Add Filter and choose Focus Guard.")
                Step(3, "Set Profile to “\(profile.name)” and click Add.")
                Step(4, "Switch that Focus on once. This line turns green when Focus Guard sees it.")
            }
            .padding(.vertical, 2)
        } header: {
            Text("Connect a Focus")
        } footer: {
            Text("One profile can be connected to several Focuses. Each Focus can have one profile.")
        }
    }

    // MARK: Websites

    private var websiteSection: some View {
        Section {
            Picker("Rule", selection: $profile.siteMode) {
                Text("Block these").tag(ListMode.block)
                Text("Allow only these").tag(ListMode.allow)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(locked)

            ForEach(profile.sites, id: \.self) { site in
                HStack {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(site)
                        if let also = aliasNote(for: site) {
                            Text(also).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        profile.sites.removeAll { $0 == site }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(locked)
                    .accessibilityLabel("Remove \(site)")
                }
            }

            HStack {
                TextField("Add website", text: $newSite, prompt: Text("example.com"))
                    .onSubmit(addSites)
                Button("Add", action: addSites)
                    .disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .disabled(locked)
            if let siteError {
                Text(siteError).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Websites")
        } footer: {
            Text(siteFooter)
        }
    }

    private var siteFooter: String {
        switch profile.siteMode {
        case .block:
            return "A site covers its subdomains. Add a path, like linkedin.com/feed, to block one part of a site and leave the rest."
        case .allow:
            return profile.sites.isEmpty
                ? "With nothing on this list, every website is blocked while the Focus is on."
                : "Every website not on this list is blocked while the Focus is on, including sign-in pages on other domains."
        }
    }

    private func aliasNote(for site: String) -> String? {
        guard let rule = SiteRule(site) else { return nil }
        let extra = SiteAliases.expansions(of: rule).map(\.text)
        return extra.isEmpty ? nil : "Also covers \(extra.formatted(.list(type: .and)))"
    }

    private func addSites() {
        let typed = newSite.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        let parsed = SitePolicy.parse(typed)
        guard !parsed.isEmpty else {
            siteError = "“\(typed)” isn't a website address. Type a domain, like x.com."
            return
        }
        siteError = nil
        for site in parsed where !profile.sites.contains(site) {
            profile.sites.append(site)
        }
        newSite = ""
    }

    // MARK: Apps

    private var appSection: some View {
        Section {
            Picker("Rule", selection: $profile.appMode) {
                Text("Block these").tag(ListMode.block)
                Text("Allow only these").tag(ListMode.allow)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(locked)

            ForEach(profile.apps) { app in
                HStack {
                    AppIcon(bundleID: app.bundleID)
                    Text(app.name)
                    Spacer()
                    Button {
                        profile.apps.removeAll { $0.bundleID == app.bundleID }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(locked)
                    .accessibilityLabel("Remove \(app.name)")
                }
            }

            Menu("Add App") {
                let running = runningApps()
                if !running.isEmpty {
                    Section("Open now") {
                        ForEach(running) { app in
                            Button(app.name) { add(app) }
                        }
                    }
                }
                Button("Choose from Applications…", action: chooseApps)
            }
            .fixedSize()
            .disabled(locked)
        } header: {
            Text("Apps")
        } footer: {
            Text(appFooter)
        }
    }

    private var appFooter: String {
        switch profile.appMode {
        case .block:
            return "These apps are quit when the Focus goes on, and quit again if opened."
        case .allow:
            return "Every other app is hidden whenever it comes to the front. Finder and System Settings are always allowed. Add your browser here if you want to use it."
        }
    }

    private func runningApps() -> [AppRef] {
        let listed = Set(profile.apps.map(\.bundleID))
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AppRef? in
                guard let bundleID = app.bundleIdentifier, !listed.contains(bundleID),
                      bundleID != Bundle.main.bundleIdentifier
                else { return nil }
                return AppRef(bundleID: bundleID, name: app.localizedName ?? bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func add(_ app: AppRef) {
        guard !profile.apps.contains(where: { $0.bundleID == app.bundleID }) else { return }
        profile.apps.append(app)
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            add(AppRef(bundleID: bundleID, name: name))
        }
    }

    // MARK: Hold

    private var holdSection: some View {
        let onName = FocusHold.onName(profile)
        let offName = FocusHold.offName(profile)
        let hasOn = session.shortcutNames.contains(onName)
        let hasOff = session.shortcutNames.contains(offName)

        return Section {
            LabeledContent {
                Button("Add Shortcuts…") { offerShortcuts() }
            } label: {
                if hasOn && hasOff {
                    Label("The Focus stays on through the cool-down", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("The Focus icon goes off during the cool-down", systemImage: "circle.dashed")
                }
            }
            ShortcutRow(name: onName, found: hasOn, action: "Turn the Focus On until Turned Off")
            ShortcutRow(name: offName, found: hasOff, action: "Turn the Focus Off")
            if let holdMessage {
                Text(holdMessage).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Keep the Focus itself on")
        } footer: {
            Text("Optional. Blocking lasts through the cool-down either way. macOS lets an app switch a Focus only through Shortcuts, so these two shortcuts are how Focus Guard turns the Focus back on when you click it off, keeps notifications silenced for the wait, and turns it off at the end. To make one by hand: new shortcut, add the Set Focus action, choose the Focus, and give it the exact name shown.")
        }
        .onAppear { session.refreshShortcuts() }
    }

    private func offerShortcuts() {
        holdMessage = "Shortcuts will open twice. Each time, choose the Focus and click Add Shortcut."
        let current = profile
        Task {
            do {
                try await FocusHold.offerShortcuts(for: current)
            } catch {
                holdMessage = error.localizedDescription
            }
            // Give the person time to click through, then look again.
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                session.refreshShortcuts()
            }
        }
    }
}

private struct Step: View {
    let number: Int
    let text: String

    init(_ number: Int, _ text: String) {
        self.number = number
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}

private struct ShortcutRow: View {
    let name: String
    let found: Bool
    let action: String

    var body: some View {
        HStack {
            Image(systemName: found ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(found ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).textSelection(.enabled)
                Text(found ? "Found in Shortcuts" : "Not in Shortcuts. Action: \(action)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AppIcon: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.dashed")
                .frame(width: 20, height: 20)
                .foregroundStyle(.secondary)
        }
    }
}
