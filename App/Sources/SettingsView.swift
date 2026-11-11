import AppKit
import FocusGuardCore
import SwiftUI

struct SettingsView: View {
    enum Selection: Hashable {
        case setup
        case profile(String)
    }

    @EnvironmentObject private var session: SessionController
    @State private var selection: Selection? = .setup

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Setup", systemImage: "checklist")
                    .tag(Selection.setup)
                Section("Profiles") {
                    ForEach(session.config.profiles) { profile in
                        Label {
                            Text(profile.name.isEmpty ? "Untitled" : profile.name)
                        } icon: {
                            Image(systemName: session.state.profileID == profile.id ? "shield.fill" : "shield")
                        }
                        .tag(Selection.profile(profile.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button(action: addProfile) {
                        Label("New Profile", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(session.isLocked)
                    Spacer()
                }
                .padding(10)
            }
        } detail: {
            VStack(spacing: 0) {
                if session.isLocked { LockedBanner() }
                detail
            }
        }
        .onAppear {
            if selection == .setup, let first = session.config.profiles.first, session.lastSeen[first.id] != nil {
                selection = .profile(first.id)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .profile(let id):
            if let binding = binding(for: id) {
                ProfileEditor(profile: binding, onDelete: { delete(id) })
                    .id(id)
            } else {
                SetupPane(onAddProfile: addProfile)
            }
        case .setup, .none:
            SetupPane(onAddProfile: addProfile)
        }
    }

    private func binding(for id: String) -> Binding<Profile>? {
        guard session.config.profile(id) != nil else { return nil }
        return Binding(
            get: { session.config.profile(id) ?? Profile(id: id, name: "") },
            set: { updated in
                guard !session.isLocked,
                      let index = session.config.profiles.firstIndex(where: { $0.id == id })
                else { return }
                session.config.profiles[index] = updated
            })
    }

    private func addProfile() {
        guard !session.isLocked else { return }
        let taken = Set(session.config.profiles.map(\.name))
        var name = "New Profile"
        var counter = 2
        while taken.contains(name) {
            name = "New Profile \(counter)"
            counter += 1
        }
        let profile = Profile(name: name)
        session.config.profiles.append(profile)
        selection = .profile(profile.id)
    }

    private func delete(_ id: String) {
        guard !session.isLocked else { return }
        selection = .setup
        session.config.profiles.removeAll { $0.id == id }
    }
}

private struct LockedBanner: View {
    @EnvironmentObject private var session: SessionController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
            Text(message)
            Spacer()
            if case .coolingDown = session.state {
                Button("Stay Focused") { session.cancelCooldown() }
            }
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.tint.opacity(0.12))
    }

    private var message: String {
        let name = session.activeProfile?.name ?? "A profile"
        if let remaining = session.remaining {
            return "\(name) ends in \(formatCountdown(remaining)). Rules can't be changed until then."
        }
        return "\(name) is on. Rules can't be changed while a session is running."
    }
}

// MARK: - Setup

struct SetupPane: View {
    @EnvironmentObject private var session: SessionController
    @StateObject private var access = BrowserAccess()
    @State private var backgroundError: String?
    @State private var backgroundOn = Background.isEnabled
    @State private var fallbackOff = DirectFallback.isOff
    @State private var changingFallback = false
    let onAddProfile: () -> Void

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Block what pulls you away, for as long as a Focus is on")
                        .font(.title2.weight(.semibold))
                    Text("A profile is a list of websites and apps. Connect it to a Focus, and its rules hold while that Focus is on. Switching the Focus off starts a countdown. Blocking ends when it runs out, and you can call it off at any point.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section("1. Make a profile") {
                if session.config.profiles.isEmpty {
                    LabeledContent("No profiles yet") {
                        Button("New Profile", action: onAddProfile)
                            .buttonStyle(.borderedProminent)
                            .disabled(session.isLocked)
                    }
                } else {
                    ForEach(session.config.profiles) { profile in
                        LabeledContent(profile.name) {
                            ConnectionStatus(lastSeen: session.lastSeen[profile.id])
                        }
                    }
                    Text("Choose a profile in the sidebar to edit its lists and connect it to a Focus.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if access.browsers.isEmpty {
                    Text("No supported browser is installed.")
                        .foregroundStyle(.secondary)
                }
                ForEach(access.browsers) { browser in
                    BrowserRow(browser: browser, permission: access.status[browser.bundleID]) {
                        access.grant(browser)
                    }
                }
                if !access.unreadable.isEmpty {
                    Text("\(access.unreadable.map(\.name).formatted(.list(type: .and))) can't report which pages are open, so \(access.unreadable.count == 1 ? "it is" : "they are") closed while a profile with website rules is on.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("2. Let Focus Guard read your browsers")
            } footer: {
                Text("Website rules work by reading the address of each open tab. macOS asks once per browser. A browser you refuse is closed while website rules are on.")
            }

            Section {
                Toggle("Keep Focus Guard running", isOn: Binding(
                    get: { backgroundOn },
                    set: { setBackground($0) }))
                    .disabled(session.isLocked || !Background.isInstalledCopy)
                Text(backgroundError ?? Background.statusText)
                    .font(.callout)
                    .foregroundStyle(backgroundError == nil ? .secondary : .primary)
            } header: {
                Text("3. Stay on")
            } footer: {
                Text("With this off, nothing restarts Focus Guard if it is quit or force-quit, and blocking ends with it.")
            }

            Section {
                LabeledContent {
                    if fallbackOff {
                        Button("Undo…") { setFallback(off: false) }.disabled(changingFallback || session.isLocked)
                    } else {
                        Button("Set Up…") { setFallback(off: true) }.disabled(changingFallback)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Apps built on Chromium", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        if fallbackOff {
                            Label("Apps built on WebKit", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("Apps built on WebKit need one more setting", systemImage: "circle.dashed")
                        }
                    }
                }
            } header: {
                Text("4. Built-in browsers in other apps")
            } footer: {
                Text("While a profile is on, the sites on its block list are refused across the Mac, which reaches the browsers built into apps like Claude, Codex and Engelbart. Apps built on WebKit only respect that once macOS is told not to retry a refused connection directly. Changing that setting takes your password, once. With it on, if Focus Guard is ever missing during a session, Safari and other WebKit apps show every site as offline: switch off Automatic Proxy Configuration under Network › Details › Proxies to recover. Path rules and allow lists don't apply inside other apps.")
            }

            Section("Record") {
                LabeledContent("Log of sessions and blocked pages") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Paths.log])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { access.startWatching() }
        .onDisappear { access.stopWatching() }
    }

    private func setFallback(off: Bool) {
        changingFallback = true
        DispatchQueue.global(qos: .userInitiated).async {
            _ = DirectFallback.set(off: off)
            let now = DirectFallback.isOff
            DispatchQueue.main.async {
                fallbackOff = now
                changingFallback = false
            }
        }
    }

    private func setBackground(_ on: Bool) {
        backgroundError = nil
        if on {
            do {
                try Background.enable()
            } catch {
                backgroundError = "macOS refused: \(error.localizedDescription)"
            }
            backgroundOn = Background.isEnabled
        } else {
            backgroundOn = false
            Background.disable { error in
                if let error { backgroundError = "macOS refused: \(error.localizedDescription)" }
                backgroundOn = Background.isEnabled
            }
        }
    }
}

private struct ConnectionStatus: View {
    let lastSeen: Date?

    var body: some View {
        if let lastSeen {
            Label("Switched on by a Focus \(lastSeen.formatted(.relative(presentation: .named)))",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label("Not connected to a Focus yet", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }
}

private struct BrowserRow: View {
    let browser: Browsers.Installed
    let permission: Browsers.Permission?
    let onGrant: () -> Void

    var body: some View {
        LabeledContent {
            switch permission {
            case .granted:
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .denied:
                Button("Open Automation Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
            case .notAsked:
                Button("Allow…", action: onGrant)
            case .notRunning:
                Button("Open \(browser.name)") {
                    NSWorkspace.shared.openApplication(at: browser.url, configuration: .init())
                }
            case .unknown, .none:
                Text("Checking…").foregroundStyle(.secondary)
            }
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: browser.url.path))
                    .resizable()
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(browser.name)
                    if permission == .denied {
                        Text("Refused. Turn it on under Focus Guard in Automation.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if permission == .notRunning {
                        Text("Open it to check access.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Watches whether macOS lets this app read each browser. The question can
/// block while a prompt is on screen, so it is asked off the main thread.
@MainActor
final class BrowserAccess: ObservableObject {
    @Published private(set) var status: [String: Browsers.Permission] = [:]
    let browsers = Browsers.installedReadable()
    let unreadable = Browsers.installedUnreadable()
    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.mathetic.FocusGuard.access")

    func startWatching() {
        refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    func grant(_ browser: Browsers.Installed) {
        ask(browser.bundleID, prompting: true)
    }

    private func refresh() {
        for browser in browsers { ask(browser.bundleID, prompting: false) }
    }

    private func ask(_ bundleID: String, prompting: Bool) {
        queue.async {
            let result = Browsers.permission(for: bundleID, ask: prompting)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.status[bundleID] != result else { return }
                self.status[bundleID] = result
            }
        }
    }
}
