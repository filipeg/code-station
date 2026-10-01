import Foundation
import Testing
@testable import MenuBarApp

struct HomeWorkMapTests {
    private func live(project: UUID = UUID(), workspace: UUID? = nil,
                      name: String = "Project", tone: SessionTone = .running,
                      permission: PermissionRequest? = nil, finished: Bool = false,
                      destination: SessionDestination = .conversation) -> HomeLive {
        var session = ChatSession(projectID: project, agent: .codex)
        session.workspaceID = workspace
        return HomeLive(session: session, containerName: name,
                        tint: Theme.projectTint(for: name),
                        avatar: SidebarAvatar(subject: workspace == nil ? .project : .workspace,
                                              id: workspace ?? project),
                        tone: tone, activity: "Working", location: "project folder",
                        destination: destination, permission: permission, finished: finished)
    }

    private var permission: PermissionRequest {
        PermissionRequest(id: "request", toolName: "Bash", title: "Run checks",
                          subject: "swift test", detail: "", input: Data(),
                          suggestions: nil, alwaysTitle: nil, questions: [])
    }

    @Test func groupsByIdentityAndKeepsWorkspaceSessionsTogether() {
        let project = UUID()
        let workspace = UUID()
        let standalone = live(project: project)
        let attached = live(project: project, workspace: workspace)
        let otherLead = live(workspace: workspace)
        let sameName = live()
        let idle = live(tone: .idle)
        let map = HomeWorkMap(sessions: [standalone, attached, otherLead, sameName, idle])

        #expect(map.groups.count == 3)
        #expect(map.groups.first { $0.id == workspace }?.sessions.count == 2)
        #expect(map.active.count == 4)
        #expect(map.sessions.count == 5)
    }

    @Test func countsWorkSeparatelyFromBackgroundWaitsAndAttention() {
        let map = HomeWorkMap(sessions: [live(), live(tone: .waiting),
                                        live(tone: .needsYou), live(tone: .idle)])
        #expect(map.runningCount == 1)
        #expect(map.waiting.count == 1)
        #expect(map.active.count == 3)
    }

    @Test func startsWithPermissionAndPreservesAnExplicitSelection() {
        let request = live(tone: .needsYou, permission: permission)
        let review = live(tone: .needsYou, finished: true)
        let running = live()
        let map = HomeWorkMap(sessions: [running, review, request])

        #expect(map.selection(nil, needsYouOnly: false)?.id == request.id)
        #expect(map.selection(running.id, needsYouOnly: false)?.id == running.id)
        #expect(map.selection(running.id, needsYouOnly: true)?.id == request.id)
        #expect(map.selection(review.id, needsYouOnly: true)?.id == review.id)
    }

    @Test func selectionRecoversAfterDeletionOrAttentionClears() {
        let running = live()
        let idle = live(tone: .idle)
        let map = HomeWorkMap(sessions: [running, idle])
        #expect(map.selection(UUID(), needsYouOnly: false)?.id == running.id)
        #expect(map.selection(idle.id, needsYouOnly: false)?.id == idle.id)
        #expect(map.selection(running.id, needsYouOnly: true) == nil)
        #expect(HomeWorkMap(sessions: []).selection(nil, needsYouOnly: false) == nil)
    }

    @Test func routesReviewToChangesOnlyWhenThereAreChanges() {
        let review = live(tone: .needsYou, finished: true)
        #expect(review.primaryAction(hasChanges: true).destination == .changes)
        #expect(review.primaryAction(hasChanges: false).destination == .conversation)
        let stale = live(tone: .needsYou)
        #expect(stale.primaryAction(hasChanges: true).title == "Open session")
        #expect(stale.status == "Needs your attention")
    }

    @Test func permissionsAndDesignsKeepTheirConversationDestination() {
        let request = live(tone: .needsYou, permission: permission)
        #expect(request.primaryAction(hasChanges: true).destination == .conversation)
        #expect(request.primaryAction(hasChanges: true).title == "View request")
        let design = live(tone: .needsYou, permission: permission, destination: .design)
        #expect(design.primaryAction(hasChanges: true).destination == .design)
        let designReview = live(tone: .needsYou, finished: true, destination: .design)
        #expect(designReview.primaryAction(hasChanges: true).destination == .design)
    }
}
