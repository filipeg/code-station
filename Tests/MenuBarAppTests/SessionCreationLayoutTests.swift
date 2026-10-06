import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct SessionCreationLayoutTests {
    @Test func twoStaleProjectSummariesFitWithoutExpandingChoices() throws {
        let (store, _) = TestStore.make()
        let first = try TestStore.project(in: store, named: "zectrix")
        let second = try TestStore.project(in: store, named: "japan")
        let report = GitFreshness.Report(currentBranch: "main", defaultBranch: "main",
                                         remoteRef: "origin/main", behind: 1,
                                         fetchAttempted: true, fetched: true)
        let view = VStack(spacing: 10) {
            ForEach([first, second]) { project in
                SessionProjectCard(project: project, lead: project.id == first.id,
                                   usesWorktree: true, report: report,
                                   startPoint: .constant(.updateCheckout),
                                   selectWorktree: {}, selectProjectFolder: {}, onChoose: {})
            }
        }
        .frame(width: 732)
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        #expect(size.height > 200)
        #expect(size.height < 440)
        #expect(size.width == 732)
    }
}
