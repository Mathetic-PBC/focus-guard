import AppKit
import SwiftUI

/// The countdown shown while a Focus is on its way off. It floats above
/// everything, on every Space, and does not take the keyboard from whatever
/// is being worked on.
@MainActor
final class CooldownPanel {
    private var panel: NSPanel?

    func show(profileName: String, until: Date, onStay: @escaping () -> Void) {
        hide()
        let view = CooldownView(profileName: profileName, until: until, onStay: onStay)
        let host = NSHostingView(rootView: view)
        host.setFrameSize(host.fittingSize)

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: host.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        if let screen = NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: area.midX - host.fittingSize.width / 2,
                y: area.maxY - host.fittingSize.height - 16))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.close()
        panel = nil
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct CooldownView: View {
    let profileName: String
    let until: Date
    let onStay: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text(formatCountdown(until.timeIntervalSince(context.date)))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 76, alignment: .leading)
                    .contentTransition(.numericText(countsDown: true))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(profileName) is ending")
                    .font(.headline)
                Text("Blocking stays on until the timer runs out.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Stay Focused", action: onStay)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator))
        .accessibilityElement(children: .contain)
    }
}
