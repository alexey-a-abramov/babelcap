import AppKit
import SwiftUI

/// Tooltips that also work in Babelcap's floating panels.
///
/// System tooltips (`.help`) are not shown for non-activating panels while another app is active — which is how
/// the control panel and the subtitles are always used. This draws its own little tooltip window near the pointer.
@MainActor
public final class TooltipCenter {
    public static let shared = TooltipCenter()

    private let panel: NSPanel
    private let host: NSHostingView<TooltipLabel>
    private var pending: Task<Void, Never>?
    private var owner: UUID?
    private var clickMonitor: Any?

    private init() {
        host = NSHostingView(rootView: TooltipLabel(text: ""))
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = host
        // Any click hides the tooltip (it would otherwise linger over a pressed button).
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            MainActor.assumeIsolated { self?.hideNow() }
            return e
        }
    }

    public func hover(_ text: String, owner id: UUID) {
        pending?.cancel()
        owner = id
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, self.owner == id else { return }
            self.present(text)
        }
    }

    public func leave(owner id: UUID) {
        guard owner == id else { return }
        hideNow()
    }

    private func hideNow() {
        pending?.cancel()
        owner = nil
        panel.orderOut(nil)
    }

    private func present(_ text: String) {
        host.rootView = TooltipLabel(text: text)
        let size = host.fittingSize
        let m = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? .infinite
        var origin = NSPoint(x: m.x - size.width / 2, y: m.y - size.height - 22)          // below the pointer
        if origin.y < vis.minY { origin.y = m.y + 18 }                                    // …or above it near the bottom
        origin.x = min(max(origin.x, vis.minX + 4), vis.maxX - size.width - 4)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }
}

struct TooltipLabel: View {
    let text: String
    static let fontSize: CGFloat = 11.5
    static let maxWidth: CGFloat = 300

    /// Single-line width, capped — wrapping then happens at a fixed width so the height can follow the line count.
    private var textWidth: CGFloat {
        let w = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: Self.fontSize)]).width
        return min(ceil(w) + 2, Self.maxWidth)
    }

    var body: some View {
        Text(text)
            .font(.system(size: Self.fontSize))
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .frame(width: textWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(white: 0.13).opacity(0.97)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .fixedSize()
    }
}

private struct TipModifier: ViewModifier {
    let text: String
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside { TooltipCenter.shared.hover(text, owner: id) } else { TooltipCenter.shared.leave(owner: id) }
            }
            .onDisappear { TooltipCenter.shared.leave(owner: id) }
            .accessibilityHint(text)
    }
}

public extension View {
    /// A tooltip that works in floating, non-activating panels (use instead of `.help`).
    func tip(_ text: String) -> some View { modifier(TipModifier(text: text)) }
}
