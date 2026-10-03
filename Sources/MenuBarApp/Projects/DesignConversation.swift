import AppKit
import SwiftUI

enum DesignConversationLayout {
    static let headerHeight: CGFloat = 53

    static func inset(in workspace: CGSize) -> CGFloat {
        min(workspace.width < 720 ? 12 : 22, max(0, min(workspace.width, workspace.height) / 2))
    }

    // With the history hidden the folded panel is just the header and the composer, so it
    // follows the composer's measured height instead of leaving a gap under it.
    static func size(in workspace: CGSize, expanded: Bool, historyHidden: Bool = false,
                     composerHeight: CGFloat = 167) -> CGSize {
        let margin = inset(in: workspace) * 2
        let available = CGSize(width: max(0, workspace.width - margin),
                               height: max(0, workspace.height - margin))
        guard expanded else {
            return CGSize(width: min(660, available.width), height: min(historyHidden ? headerHeight + composerHeight : 326, available.height))
        }
        return available
    }

}

// Observe presses without taking them away from the canvas or composer: a press on the
// folded panel opens it, and a press outside the open panel folds it.
struct DesignConversationDismissal: NSViewRepresentable {
    let expanded: Bool
    let enabled: Bool
    let collapse: (Bool) -> Void
    let expand: () -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.expanded = expanded
        view.enabled = enabled
        view.collapse = collapse
        view.expand = expand
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.stop() }

    final class ObserverView: NSView {
        var expanded = false
        var enabled = true
        var collapse: ((Bool) -> Void)?
        var expand: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return stop() }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.handle(event, frontmost: NSApp.keyWindow) == nil
                }
                return consumed ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            collapse = nil
            expand = nil
        }

        func handle(_ event: NSEvent, frontmost: NSWindow?) -> NSEvent? {
            guard enabled, !isHiddenOrHasHiddenAncestor, let window,
                  event.window === window, window.attachedSheet == nil else { return event }
            let point = convert(event.locationInWindow, from: nil)
            guard expanded else {
                // The header has its own fold buttons, so a press there is left to them.
                let header = isFlipped ? point.y < DesignConversationLayout.headerHeight
                    : point.y > bounds.maxY - DesignConversationLayout.headerHeight
                if event.type == .leftMouseDown, bounds.contains(point), !header {
                    expand?()
                }
                return event
            }
            if event.type == .keyDown {
                guard event.keyCode == 53,
                      WindowKeyMonitor.routes(to: window, frontmost: frontmost)
                else { return event }
                collapse?(true)
                return nil
            }
            if !bounds.contains(point) {
                collapse?(false)
            }
            return event
        }
    }
}
