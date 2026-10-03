import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// Reports the height a view asks for when it is offered one, which is how a sheet that
// cannot be made shorter gives itself away.
private struct HeightProbe: Layout {
    let report: (CGFloat) -> Void

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(proposal)
        report(size.height)
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
    }
}

@MainActor
private final class MeasuredHeight {
    var value: CGFloat = 0
}

// A sheet that asks for more height than the window it opens over is clipped rather than
// shrunk, and it is clipped from the middle out, so both of its ends go: the header at
// the top and the footer, with the Create button in it, at the bottom. The new session
// sheet grows once the branch check comes back, so it has to be able to give that height
// up again when the window is short.
struct NewSessionSheetSizeTests {

    @MainActor
    @Test func theSheetGivesUpHeightToAShortWindow() throws {
        let settings = AppSettings(
            agentAvatarURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("avatar.png"),
            preferences: UserDefaults(suiteName: "sheet-size-\(UUID().uuidString)") ?? .standard)
        let measured = MeasuredHeight()
        let host = NSHostingView(rootView: HeightProbe(report: { measured.value = $0 }) {
            NewSessionView(project: Project(name: "probe", path: NSTemporaryDirectory())) { _ in }
                .environment(SessionRunner(paths: [:]))
                .environment(DialogPresenter())
                .environment(MenuPresenter())
                .environment(TooltipPresenter())
                .environment(settings)
        })

        host.frame = NSRect(x: 0, y: 0, width: 560, height: 800)
        host.layoutSubtreeIfNeeded()
        let asked = measured.value
        #expect(asked > 200)

        host.frame = NSRect(x: 0, y: 0, width: 560, height: 200)
        host.layoutSubtreeIfNeeded()
        #expect(measured.value <= 200)
    }

    @MainActor
    @Test func workspaceSheetKeepsItsActionsWithinAShortWindow() throws {
        let (store, scratch) = TestStore.make()
        defer { withExtendedLifetime(scratch) {} }
        let first = try TestStore.project(in: store, named: "api")
        let second = try TestStore.project(in: store, named: "web")
        let workspace = ProjectWorkspace(name: "Payments", projectIDs: [first.id, second.id],
                                         leadProjectID: first.id)
        let settings = AppSettings(
            agentAvatarURL: scratch.url.appendingPathComponent("avatar.png"),
            preferences: UserDefaults(suiteName: "workspace-sheet-size-\(UUID().uuidString)")!)
        let measured = MeasuredHeight()
        let host = NSHostingView(rootView: HeightProbe(report: { measured.value = $0 }) {
            NewWorkspaceSessionView(workspace: workspace) { _ in }
                .environment(store)
                .environment(SessionRunner(paths: [.claudeCode: "/usr/bin/true"]))
                .environment(DialogPresenter())
                .environment(MenuPresenter())
                .environment(TooltipPresenter())
                .environment(settings)
        })

        for width: CGFloat in [560, 850] {
            host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
            host.layoutSubtreeIfNeeded()
            #expect(measured.value > 200)
            #expect(measured.value <= 400)
        }
    }

}
