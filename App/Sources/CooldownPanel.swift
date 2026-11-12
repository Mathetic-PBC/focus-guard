import AppKit
import SwiftUI

/// The countdown shown while a Focus is on its way off. It floats above
/// everything, on every Space, and does not take the keyboard from whatever
/// is being worked on.
///
/// It can be dragged anywhere, by any part that isn't the button, and comes
/// up where it was last left.
@MainActor
final class CooldownPanel {
    private static let originKey = "cooldownPanelOrigin"

    private var panel: DraggablePanel?

    func show(profileName: String, until: Date, onStay: @escaping () -> Void) {
        hide()
        let layout = PanelLayout()
        let view = CooldownView(profileName: profileName, until: until, layout: layout, onStay: onStay)
        let host = NSHostingView(rootView: view)
        host.setFrameSize(host.fittingSize)

        let panel = DraggablePanel(
            contentRect: NSRect(origin: .zero, size: host.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.layout = layout
        panel.onDrag = { [weak self] origin in self?.move(to: origin) }
        panel.onDragEnd = { [weak self] in self?.remember() }

        panel.setFrameOrigin(Self.startingOrigin(for: host.fittingSize))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.close()
        panel = nil
    }

    /// Where the panel was last left, if that spot is still on a screen.
    /// Otherwise the top middle of the main screen.
    private static func startingOrigin(for size: NSSize) -> NSPoint {
        if let saved = UserDefaults.standard.string(forKey: originKey) {
            let origin = NSPointFromString(saved)
            let frame = NSRect(origin: origin, size: size)
            if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) {
                return clamp(origin, size: size, to: screen.visibleFrame)
            }
        }
        let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 16)
    }

    /// Keeps the whole panel on the screen, so it can't be left where the
    /// button is out of reach.
    private static func clamp(_ origin: NSPoint, size: NSSize, to area: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, area.minX), max(area.minX, area.maxX - size.width)),
            y: min(max(origin.y, area.minY), max(area.minY, area.maxY - size.height)))
    }

    private func move(to origin: NSPoint) {
        guard let panel else { return }
        let frame = NSRect(origin: origin, size: panel.frame.size)
        // The screen the panel is mostly on decides the edges it stops at, so
        // it can be carried from one display to another.
        let screen = NSScreen.screens.max { first, second in
            first.frame.intersection(frame).area < second.frame.intersection(frame).area
        }
        let area = (screen ?? NSScreen.main)?.visibleFrame ?? frame
        panel.setFrameOrigin(Self.clamp(origin, size: panel.frame.size, to: area))
    }

    private func remember() {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.originKey)
    }

    #if DEBUG
    /// Sends the panel a press, a drag and a release, as AppKit would deliver
    /// them, with the pointer scripted to travel by `offset`. `onButton`
    /// presses the button instead, which must not move anything.
    func debugDrag(by offset: NSSize, onButton: Bool = false) {
        guard let panel else { return }
        let button = panel.layout?.buttonFrame ?? .zero
        let height = panel.contentView?.bounds.height ?? panel.frame.height
        let press = onButton
            ? NSPoint(x: button.midX, y: height - button.midY)
            : NSPoint(x: 200, y: height / 2)
        let start = NSPoint(x: 500, y: 500)
        var pointer = start
        panel.pointer = { pointer }
        func send(_ type: NSEvent.EventType) {
            guard let event = NSEvent.mouseEvent(
                with: type, location: press, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { return }
            panel.sendEvent(event)
        }
        send(.leftMouseDown)
        for step in 1...4 {
            pointer = NSPoint(
                x: start.x + offset.width * CGFloat(step) / 4,
                y: start.y + offset.height * CGFloat(step) / 4)
            send(.leftMouseDragged)
        }
        send(.leftMouseUp)
        panel.pointer = { NSEvent.mouseLocation }
    }
    #endif
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// Where the button is, as the view last laid it out, in the content's own
/// coordinates (origin at the top left).
final class PanelLayout {
    var buttonFrame: CGRect = .zero
}

/// A panel that moves when pressed and dragged anywhere but its button.
///
/// The drag is handled here, on the events as they reach the window, because
/// nothing below can be relied on to do it: the SwiftUI content takes every
/// click, so AppKit's background drag never begins, and a SwiftUI drag
/// gesture measures in coordinates that move with the panel.
final class DraggablePanel: NSPanel {
    var layout: PanelLayout?
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    /// The pointer, in screen coordinates. Read from the system and not from
    /// the event, whose position is relative to a window that is moving.
    var pointer: () -> NSPoint = { NSEvent.mouseLocation }

    private var drag: (pointer: NSPoint, origin: NSPoint)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if isOnButton(event.locationInWindow) {
                super.sendEvent(event)
            } else {
                drag = (pointer(), frame.origin)
            }
        case .leftMouseDragged:
            guard let drag else { return super.sendEvent(event) }
            let now = pointer()
            onDrag?(NSPoint(x: drag.origin.x + now.x - drag.pointer.x, y: drag.origin.y + now.y - drag.pointer.y))
        case .leftMouseUp:
            guard drag != nil else { return super.sendEvent(event) }
            drag = nil
            onDragEnd?()
        default:
            super.sendEvent(event)
        }
    }

    private func isOnButton(_ point: NSPoint) -> Bool {
        guard let button = layout?.buttonFrame, !button.isEmpty else { return false }
        let height = contentView?.bounds.height ?? frame.height
        return button.insetBy(dx: -4, dy: -4).contains(NSPoint(x: point.x, y: height - point.y))
    }
}

private struct CooldownView: View {
    let profileName: String
    let until: Date
    let layout: PanelLayout
    let onStay: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "circle.grid.2x3.fill")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
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
                .background(GeometryReader { geometry in
                    Color.clear
                        .onAppear { layout.buttonFrame = geometry.frame(in: .global) }
                        .onChange(of: geometry.frame(in: .global)) { _, frame in layout.buttonFrame = frame }
                })
        }
        .padding(.leading, 14)
        .padding(.trailing, 20)
        .padding(.vertical, 14)
        .frame(width: 530)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator))
        .help("Drag to move")
        .accessibilityElement(children: .contain)
    }
}
