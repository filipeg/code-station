import Foundation

// Taking a project out of the app. The action is offered from three places - the sidebar's
// context menu and the banner in each detail pane - and all three make the same promises
// about what goes and what stays, so the whole removal lives here rather than in each of
// them: a promise kept in one copy and forgotten in another is a promise the app breaks.
@MainActor
enum ProjectRemoval {

    // The removal end to end: ask, do the work, and say so if any of it failed. A caller
    // that borrowed only a piece of this would be one forgotten error report away from a
    // button that looks like it did nothing.
    static func confirm(_ project: Project, in store: ProjectStore, runner: SessionRunner,
                        shortcuts: ShortcutStore, dialogs: DialogPresenter,
                        worktrees: WorktreeOperations = .live) {
        dialogs.show(confirmation(for: project, in: store, shortcuts: shortcuts) {
            Task {
                if case .failure(let failure) = await run(project, in: store, runner: runner,
                                                          shortcuts: shortcuts,
                                                          worktrees: worktrees) {
                    dialogs.show(.notice(failure.title, message: failure.message))
                }
            }
        })
    }

    // Every session with a checkout in this project, which is more than the sessions that
    // call it home: a workspace session dies with any one of its repositories.
    static func sessions(using projectID: UUID, in store: ProjectStore) -> [ChatSession] {
        store.sidebarSessions.filter { session in
            store.checkoutProjects(for: session).contains { $0.projectID == projectID }
        }
    }

    // A task's folder was created by the app inside its own support directory, so deleting
    // the task takes the folder with it. A folder the user chose always stays.
    static func confirmation(for project: Project, in store: ProjectStore,
                             shortcuts: ShortcutStore? = nil,
                             onConfirm: @escaping () -> Void) -> Dialog {
        let sessions = sessions(using: project.id, in: store)
        let count = sessions.count
        let designs = sessions.count { store.hasDesignArtifacts(for: $0) }
        let isTask = project.kind == .adHoc
        if !isTask {
            let worktreeCount = sessions.reduce(0) {
                $0 + store.checkoutProjects(for: $1).compactMap(\.worktreePath).count
            }
            let saved = shortcuts?.shortcuts.filter { $0.projectID == project.id } ?? []
            var rows = [Dialog.Impact.Row(
                title: "\(counted(count, "session")) and \(counted(worktreeCount, "worktree"))",
                detail: count == 0 ? "No sessions or worktrees to remove."
                    : "Session history is removed from Code Station."
                        + (worktreeCount > 0 ? " Worktrees are removed from disk." : ""))]
            if !saved.isEmpty {
                rows.append(.init(title: counted(saved.count, "saved shortcut"),
                                  detail: "Project commands and prompts are permanently removed."))
            }
            if designs > 0 {
                rows.append(.init(title: "Generated Design files",
                                  detail: "Permanently removed from \(counted(designs, "session"))."))
            }
            rows.append(.init(title: "Original project folder stays",
                              detail: project.collapsedPath, kept: true))
            var dialog = Dialog.confirm("Remove \(project.name)?",
                                        message: "This project will leave Code Station and every workspace it belongs to.",
                                        action: "Remove project", handler: onConfirm)
            dialog.width = 500
            dialog.impact = .init(projectName: project.name, rows: rows,
                                  warning: count > 0 ? "Session history cannot be restored." : nil)
            return dialog
        }
        var message = "This drops its \(counted(count, "run")) and deletes the task's folder, including any files the runs left in it."
        if designs > 0 {
            message += designs == 1
                ? " One session contains generated Design files that are permanently removed."
                : " \(designs) sessions contain generated Design files that are permanently removed."
        }
        return .confirm("Delete \(project.name)?",
                        message: message,
                        action: "Delete task", handler: onConfirm)
    }

    // Sessions first, project last: a project dropped while one of its sessions survived
    // would leave that session with no home, so a session that refuses to go keeps the
    // project it belongs to. The sessions that did go are already gone by then, so what
    // is left is a project the reader can remove again once the refusal is dealt with.
    static func run(_ project: Project, in store: ProjectStore, runner: SessionRunner,
                    shortcuts: ShortcutStore, worktrees: WorktreeOperations = .live) async
        -> Result<Void, SessionLifecycle.Failure> {
        if case .failure(let failure) = await SessionRemoval.run(
            sessions(using: project.id, in: store), in: store, runner: runner,
            worktrees: worktrees, groupNoun: project.kind == .adHoc ? "runs" : "sessions") {
            return .failure(failure)
        }
        // The commands saved against the project go with it. Nothing can bring them back
        // by re-adding the folder - a project added again is a new one - so leaving them
        // would only mean rows filed under a name the app no longer knows.
        shortcuts.removeAll(ownedBy: project.id)
        store.removeProject(project.id)
        return .success(())
    }
}
