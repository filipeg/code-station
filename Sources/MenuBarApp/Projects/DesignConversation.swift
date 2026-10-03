import AppKit
import SwiftUI

enum DesignConversationLayout {
    static let headerHeight: CGFloat = 53

    static func inset(in workspace: CGSize) -> CGFloat {
        min(workspace.width < 720 ? 12 : 22, max(0, min(workspace.width, workspace.height) / 2))
    }

    static func size(in workspace: CGSize, expanded: Bool, historyHidden: Bool = false) -> CGSize {
        let margin = inset(in: workspace) * 2
        let available = CGSize(width: max(0, workspace.width - margin),
                               height: max(0, workspace.height - margin))
        guard expanded else {
            return CGSize(width: min(660, available.width), height: min(historyHidden ? 220 : 326, available.height))
        }
        return available
    }

}

// Observe outside presses without taking them away from the canvas or composer.
struct DesignConversationDismissal: NSViewRepresentable {
    let expanded: Bool
    let collapse: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.expanded = expanded
        view.collapse = collapse
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.stop() }

    final class ObserverView: NSView {
        var expanded = false
        var collapse: ((Bool) -> Void)?
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
        }

        func handle(_ event: NSEvent, frontmost: NSWindow?) -> NSEvent? {
            guard expanded, !isHiddenOrHasHiddenAncestor, let window,
                  event.window === window, window.attachedSheet == nil else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53,
                      WindowKeyMonitor.routes(to: window, frontmost: frontmost)
                else { return event }
                collapse?(true)
                return nil
            }
            if !bounds.contains(convert(event.locationInWindow, from: nil)) {
                collapse?(false)
            }
            return event
        }
    }
}
