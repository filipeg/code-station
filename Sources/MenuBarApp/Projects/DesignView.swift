import AppKit
import SwiftUI

// A Design session is one conversation on the left, with the composer under it, and the
// live canvas on the right. The agent keeps reworking the same canvas, so there is only
// ever one design to look at.
struct DesignView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.textScale) private var textScale

    let sessionID: UUID
    var onOpenImplementation: (() -> Void)? = nil

    @State private var canvas = DesignCanvas()
    @State private var composerFocused = false
    @State private var conversationWidth = DesignSplitLayout.defaultConversationWidth
    @State private var dragStartConversationWidth: CGFloat?
    @State private var conversationCollapsed = false
    @State private var selectionEnabled = false
    @State private var snapshotRequest: DesignSnapshotRequest?
    @State private var preparingHandoff = false
    @State private var waitNoticeDismissed = false
    @State private var designWindow = DesignWindow()

    var body: some View {
        if let session = store.session(sessionID),
           let artifactURL = store.designArtifactURL(for: session) {
            let directory = artifactURL.deletingLastPathComponent()
            GeometryReader { geometry in
                let width = conversationCollapsed
                    ? DesignSplitLayout.collapsedWidth
                    : DesignSplitLayout.conversationWidth(
                        conversationWidth, availableWidth: geometry.size.width)

                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        Group {
                            if conversationCollapsed {
                                conversationRail
                            } else {
                                conversationColumn(session, width: width)
                            }
                        }
                        .frame(width: width)
                        .clipped()
                        Divider().overlay(Theme.hairline)
                        canvasColumn(session, directory: directory)
                    }

                    if !conversationCollapsed {
                        splitHandle(conversationWidth: width,
                                    availableWidth: geometry.size.width)
                            .offset(x: width - DesignSplitLayout.handleWidth / 2)
                    }
                }
            }
            .onAppear {
                store.hold(sessionID, for: .open)
                AppNotifier.shared.clear(
                    sessionID: store.userFacingSessionID(for: sessionID))
                composerFocused = true
            }
            .onDisappear {
                store.release(sessionID, for: .open)
                runner.forgetCanvasWidth(sessionID)
                designWindow.close()
            }
            .task(id: sessionID) { await store.transcriptReady(sessionID) }
            .task(id: directory.path) { await canvas.watch(directory) }
        } else {
            PaneMessage(icon: "paintbrush.pointed",
                        title: "This Design session is gone",
                        detail: "Choose another session from the sidebar.")
        }
    }

    private var latestPromptID: UUID? {
        store.session(sessionID)?.messages.last(where: { $0.role == .user })?.id
    }

    // MARK: - Conversation

    private func conversationColumn(_ session: ChatSession, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Conversation")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                GlyphButton(icon: "sidebar.left", side: 26) { conversationCollapsed = true }
                    .appTooltip("Hide conversation")
                    .accessibilityLabel("Hide conversation")
            }
            .padding(.horizontal, 12)
            .frame(height: DesignSplitLayout.barHeight)
            .background(Theme.card)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }

            transcript(session, width: width)
            Divider().overlay(Theme.hairline)
            turnNotices(session)
            designComposer(session)
        }
        .background(Theme.background)
    }

    private var conversationRail: some View {
        VStack(spacing: 10) {
            GlyphButton(icon: "sidebar.left", side: 26) { conversationCollapsed = false }
                .appTooltip("Show conversation")
                .accessibilityLabel("Show conversation")
            if runner.state(sessionID).isBusy {
                StateLight(tone: .running, size: 6)
                    .accessibilityLabel("Working")
            }
            Spacer()
        }
        .padding(.top, (DesignSplitLayout.barHeight - 26) / 2)
        .frame(maxWidth: .infinity)
        .background(Theme.card)
    }

    private func transcript(_ session: ChatSession, width: CGFloat) -> some View {
        let projectPath = store.workingDirectory(for: session) ?? ""
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(session.messages) { message in
                        MessageView(message: message,
                                    projectPath: projectPath,
                                    textScale: textScale,
                                    availableWidth: width - 28)
                            .equatable()
                            .environment(\.runningAgents, runner.runningAgents(sessionID))
                            .environment(\.activeTranscriptTools, runner.runningTools(sessionID))
                    }

                    if runner.state(sessionID).isBusy, runner.question(sessionID) == nil {
                        designStatus(session)
                    }

                    Color.clear.frame(height: 1).id("design-transcript-bottom")
                }
                .padding(14)
                .modifier(SentPromptCommands(agent: session.agent,
                                             workingDirectories: store.workingDirectories(for: session),
                                             latestPromptID: latestPromptID))
            }
            .defaultScrollAnchor(.bottom)
            // Anything new - a prompt, streamed text, a call, a change of state - sends
            // the conversation to its end.
            .onChange(of: transcriptShape(session)) {
                proxy.scrollTo("design-transcript-bottom", anchor: .bottom)
            }
        }
    }

    // What the agent is doing, under the conversation. A held-open turn looks exactly
    // like a working one from the outside, so a wait names the task keeping it open
    // instead of going on claiming the canvas is being worked on. Once the wait has gone
    // stale the line drops the live colour too: nothing is coming back from that task,
    // and the pane has to agree with the NEEDS YOU the header is already showing.
    @ViewBuilder
    private func designStatus(_ session: ChatSession) -> some View {
        if let waitingSince = runner.waitingSince(sessionID) {
            let stale = runner.waitIsStale(sessionID)
            let tasks = runner.backgroundTasks(sessionID)
            // Nothing arrives to redraw a parked turn, so the wait has to count itself up.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 6) {
                    StateLight(tone: stale ? .needsYou : .waiting, size: 6)
                    Text(stale
                         ? "Nothing has come back from \(BackgroundTaskPhrase.of(tasks))"
                         : "Waiting for \(BackgroundTaskPhrase.of(tasks))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(stale ? Theme.attentionText : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(RelativeTime.duration(since: waitingSince))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            // Past one task the line can only carry a count, so the names live here.
            .appTooltip {
                Tooltip(title: stale
                            ? "\(session.agent.title) answered, and the turn has been held open "
                              + "long past the point where this was going to report."
                            : "\(session.agent.title) has answered and is holding the turn open.",
                        note: tasks.map(\.label).joined(separator: "\n"))
            }
        } else {
            HStack(spacing: 6) {
                StateLight(tone: .running, size: 6)
                Text("\(session.agent.title) is shaping the canvas…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private struct TranscriptShape: Equatable {
        var messages: Int
        var characters: Int
        var tools: Int
        var question: String?
        var state: SessionState
    }

    private func transcriptShape(_ session: ChatSession) -> TranscriptShape {
        TranscriptShape(messages: session.messages.count,
                        characters: session.messages.last?.text.count ?? 0,
                        tools: session.messages.last?.tools.count ?? 0,
                        question: runner.question(sessionID)?.id,
                        state: runner.state(sessionID))
    }

    private func splitHandle(conversationWidth: CGFloat,
                             availableWidth: CGFloat) -> some View {
        Color.clear
            .frame(width: DesignSplitLayout.handleWidth)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartConversationWidth ?? conversationWidth
                        dragStartConversationWidth = start
                        self.conversationWidth = DesignSplitLayout.conversationWidth(
                            start + value.translation.width,
                            availableWidth: availableWidth)
                    }
                    .onEnded { _ in dragStartConversationWidth = nil })
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .appTooltip("Drag to resize")
            .accessibilityElement()
            .accessibilityLabel("Resize Design conversation")
            .accessibilityValue("\(Int(conversationWidth)) points wide")
            .accessibilityAdjustableAction { direction in
                let change: CGFloat = switch direction {
                case .increment: 32
                case .decrement: -32
                @unknown default: 0
                }
                self.conversationWidth = DesignSplitLayout.conversationWidth(
                    conversationWidth + change,
                    availableWidth: availableWidth)
            }
    }

    // MARK: - Composer

    private func designComposer(_ session: ChatSession) -> some View {
        let blocked = !FileManager.default.fileExists(atPath: store.workingDirectory(for: session) ?? "")
            || !runner.isAvailable(session.agent)
        return Composer(sessionID: sessionID,
                        agent: session.agent,
                        blocked: blocked,
                        isFocused: $composerFocused,
                        placeholder: composerPlaceholder(session),
                        inset: 12,
                        onOversizedPaste: attachPastedText,
                        onRecallUp: { runner.recallEarlier(sessionID, store: store) },
                        onRecallDown: { runner.recallLater(sessionID, store: store) },
                        above: {
                            ScrollView(.horizontal, showsIndicators: false) {
                                SessionRunSettingsControls(sessionID: sessionID)
                            }
                            let queued = runner.queued(sessionID).count
                            if queued > 0 {
                                Text(counted(queued, "prompt") + " queued")
                                    .font(.mono(9.5, .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        },
                        accessory: {
                            Image(systemName: "paintbrush.pointed.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 22, height: 22)
                        })
    }

    private func composerPlaceholder(_ session: ChatSession) -> String {
        if runner.state(sessionID).isBusy { return "Queue a follow-up…" }
        return session.messages.isEmpty ? "Describe what to design…" : "Refine this design…"
    }

    private func attachPastedText(_ text: String) {
        guard let attachment = Attachments.fromPastedText(text) else { return }
        runner.attach([attachment], to: sessionID)
        composerFocused = true
    }

    // Questions from the agent, a held-open turn and a failed one all sit right above
    // the composer, where the answer gets typed.
    @ViewBuilder
    private func turnNotices(_ session: ChatSession) -> some View {
        let state = runner.state(sessionID)
        let projectPath = store.workingDirectory(for: session) ?? ""
        let question = runner.question(sessionID)
        let waiting = state == .waiting && !waitNoticeDismissed
            ? runner.waitingSince(sessionID) : nil
        VStack(alignment: .leading, spacing: 10) {
            if let request = question {
                PermissionCard(request: request,
                               workingDirectories: store.workingDirectories(for: session),
                               projectPath: projectPath) { answer in
                    runner.answer(request, with: answer,
                                  sessionID: sessionID, store: store)
                }
                .id(request.id)
            }

            if let waitingSince = waiting {
                WaitingNotice(since: waitingSince,
                              tasks: runner.backgroundTasks(sessionID),
                              agentTitle: session.agent.title,
                              command: { session.shellCommand(for: $0) },
                              onKeepWaiting: { waitNoticeDismissed = true },
                              onEnd: { runner.endWait(sessionID) })
            }

            TurnEndActions(sessionID: sessionID, state: state)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, question != nil || waiting != nil || hasTurnEndAction(state) ? 10 : 0)
        // A dismissed notice is dismissed for that wait only: the next one is a new turn
        // parked on new tasks, and it has its own case to make.
        .onChange(of: state) { _, state in
            if state != .waiting { waitNoticeDismissed = false }
        }
    }

    private func hasTurnEndAction(_ state: SessionState) -> Bool {
        if case .failed = state { return true }
        return runner.canContinueAfterStop(sessionID, store: store)
    }

    // MARK: - Canvas

    private func canvasColumn(_ session: ChatSession, directory: URL) -> some View {
        let implementation = store.implementationSessions(for: session.id).last
        let needsImplementationUpdate = implementation.map {
            designNeedsUpdate(session, implementation: $0, directory: directory)
        } ?? false
        let busy = runner.state(sessionID).isBusy
        return VStack(spacing: 0) {
            DesignCanvasBar(canvas: canvas) {
                if canvas.revision != nil {
                    Text(canvas.selectedScreen?.path ?? "index.html")
                        .font(.mono(10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .appTooltip(canvas.screenURL(in: directory)?.path ?? directory.path)
                }
            } tools: {
                if canvas.revision != nil {
                    GlyphButton(icon: selectionEnabled ? "scope" : "cursorarrow", side: 28,
                                active: selectionEnabled, tint: Theme.accent) {
                        selectionEnabled.toggle()
                    }
                    .appTooltip(selectionEnabled
                        ? "Stop selecting canvas elements"
                        : "Select an element to refine")
                    .accessibilityLabel("Select an element to refine")

                    GlyphButton(icon: "arrow.up.left.and.arrow.down.right", side: 28,
                                active: designWindow.isOpen, tint: Theme.accent) {
                        openDesignWindow(session, directory: directory)
                    }
                    .appTooltip(designWindow.isOpen
                        ? "Bring design window to front"
                        : "Open design in a separate window")
                    .accessibilityLabel("Full screen")

                    if let implementation {
                        if onOpenImplementation == nil {
                            ActionButton(title: "Build", tone: .outlined,
                                         height: 28, size: 11,
                                         icon: "arrow.right") {
                                openImplementation(implementation)
                            }
                        }

                        if needsImplementationUpdate {
                            ActionButton(
                                title: preparingHandoff ? "Preparing…" : "Update build",
                                tone: .green, height: 28, size: 11,
                                icon: preparingHandoff ? "hourglass" : "arrow.triangle.2.circlepath") {
                                    implement()
                                }
                                .disabled(preparingHandoff || busy)
                        } else {
                            MonoChip(text: "BUILD UP TO DATE", size: 8.5,
                                     tint: Theme.accent)
                        }
                    } else {
                        ActionButton(title: preparingHandoff ? "Preparing…" : "Implement",
                                     tone: .green, height: 28, size: 11,
                                     icon: preparingHandoff ? "hourglass" : "hammer.fill") {
                            showImplementationDialog()
                        }
                        .disabled(preparingHandoff || busy)
                    }
                }
            }

            canvasContent(session, directory: directory, busy: busy)

            // The folded conversation rail is too narrow for the composer, so it moves here.
            if conversationCollapsed {
                Divider().overlay(Theme.hairline)
                turnNotices(session)
                designComposer(session)
            }
        }
    }

    @ViewBuilder
    private func canvasContent(_ session: ChatSession, directory: URL, busy: Bool) -> some View {
        if let revision = canvas.revision, let url = canvas.screenURL(in: directory) {
            // The agent cannot see the canvas it draws into, so the canvas tells it how
            // much room there is.
            DesignWebView(url: url,
                          readAccessURL: directory,
                          screen: canvas.selectedScreen,
                          revision: revision,
                          reloadGeneration: canvas.reloadGeneration,
                          selectionEnabled: selectionEnabled,
                          snapshotRequest: snapshotRequest,
                          onSelection: selectElement,
                          onSnapshot: receiveSnapshot,
                          onViewport: { runner.recordCanvasWidth($0, for: sessionID) })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
        } else if busy {
            PaneMessage(icon: "paintbrush.pointed",
                        title: "Building the design",
                        detail: "It appears here as soon as \(session.agent.title) writes it.")
                .background(Theme.sunken)
        } else {
            PaneMessage(icon: "rectangle.on.rectangle.angled",
                        title: "Your design appears here",
                        detail: conversationCollapsed
                            ? "Describe what to design in the prompt below."
                            : "Describe what to design in the prompt under the conversation.")
                .background(Theme.sunken)
        }
    }

    private func openDesignWindow(_ session: ChatSession, directory: URL) {
        designWindow.show(
            title: session.title,
            content: DesignWindowView(canvas: canvas,
                                      directory: directory,
                                      label: "Canvas",
                                      onClose: { designWindow.close() }))
    }

    private func selectElement(_ selection: DesignElementSelection) {
        let label = selection.text.isEmpty ? selection.tag.uppercased() : "\"\(selection.text)\""
        runner.editDraft(sessionID) { draft in
            let reference = "Refine \(label) at `\(selection.selector)`. "
            if draft.text.isEmpty { draft.text = reference }
            else if !draft.text.contains(selection.selector) { draft.text += "\n\n" + reference }
        }
        snapshotRequest = DesignSnapshotRequest(purpose: .selection,
                                                rect: selection.rect.insetBy(dx: -8, dy: -8))
        composerFocused = true
    }

    private func receiveSnapshot(_ image: NSImage?, request: DesignSnapshotRequest) {
        guard snapshotRequest?.id == request.id else { return }
        snapshotRequest = nil
        switch request.purpose {
        case .selection:
            guard let image, let attachment = Attachments.fromImage(image, prefix: "selection")
            else { return }
            runner.attach([attachment], to: sessionID)
            composerFocused = true
        case .handoff:
            Task {
                await prepareHandoff(screenshot: image.flatMap(DesignArtifacts.pngData),
                                     additionalContext: request.additionalContext)
            }
        }
    }

    // MARK: - Implementation

    private func showImplementationDialog() {
        let draft = DesignImplementationDraft()
        dialogs.show(Dialog(
            title: "Implement this Design?",
            message: "Add guidance if the canvas shows multiple options, or leave this blank to implement the Design as shown.",
            content: AnyView(DesignImplementationContextEditor(draft: draft)),
            actions: [
                .init(label: "Implement", kind: .primary) {
                    implement(additionalContext: draft.text)
                },
                .init(label: "Cancel", kind: .cancel),
            ],
            width: 460))
    }

    // Hands over the canvas as it is now. If an earlier handoff already saved these
    // exact files, that copy is approved again rather than saved a second time.
    private func implement(additionalContext: String? = nil) {
        guard canvas.revision != nil, let session = store.session(sessionID) else { return }
        preparingHandoff = true
        let directory = store.designDirectory(for: session)
        if let saved = session.designRevisions
            .sorted(by: { $0.number > $1.number })
            .first(where: { DesignArtifacts.matchesLive($0, designDirectory: directory) }) {
            switch store.approveDesignRevision(saved.id, for: sessionID) {
            case .success(let approved):
                handOver(approved, additionalContext: additionalContext)
            case .failure(let failure):
                preparingHandoff = false
                dialogs.show(.notice("Could not prepare the Design", message: failure.message))
            }
            return
        }
        snapshotRequest = DesignSnapshotRequest(purpose: .handoff,
                                                additionalContext: additionalContext)
    }

    private func prepareHandoff(screenshot: Data?, additionalContext: String?) async {
        guard let session = store.session(sessionID) else {
            preparingHandoff = false
            return
        }
        let revisions = await DesignHandoffLifecycle.sourceRevisions(for: session, store: store)
        switch store.approveDesign(sessionID, screenshot: screenshot,
                                   sourceRevisions: revisions, promptID: latestPromptID) {
        case .failure(let failure):
            preparingHandoff = false
            dialogs.show(.notice("Could not prepare the Design", message: failure.message))
        case .success(let revision):
            handOver(revision, additionalContext: additionalContext)
        }
    }

    private func handOver(_ revision: DesignRevision, additionalContext: String?) {
        preparingHandoff = false
        if let implementation = store.implementationSessions(for: sessionID).last {
            switch DesignHandoffLifecycle.sendLatestDesign(
                to: implementation.id, store: store, runner: runner) {
            case .success:
                store.append(ChatMessage(role: .system, text: "Sent the design to Build."),
                             to: sessionID)
            case .failure(let failure):
                dialogs.show(.notice(failure.title, message: failure.message))
            }
        } else {
            switch DesignHandoffLifecycle.startImplementation(
                sessionID, revision: revision, additionalContext: additionalContext,
                store: store, runner: runner) {
            case .success:
                onOpenImplementation?()
            case .failure(let failure):
                dialogs.show(.notice(failure.title, message: failure.message))
            }
        }
    }

    private func designNeedsUpdate(_ design: ChatSession, implementation: ChatSession,
                                   directory: URL) -> Bool {
        if store.designHasUpdated(for: implementation) { return true }
        guard let revisionID = implementation.handedOffDesignRevisionID,
              let revision = design.designRevisions.first(where: { $0.id == revisionID }) else {
            return true
        }
        let handedOff = DesignArtifacts.materialsDirectory(revision, designDirectory: directory)
        return DesignArtifactRevision.read(directory) != DesignArtifactRevision.read(handedOff)
    }

    private func openImplementation(_ implementation: ChatSession) {
        if let onOpenImplementation {
            onOpenImplementation()
        } else {
            store.selectSession(implementation.id)
        }
    }
}



@MainActor
@Observable
private final class DesignImplementationDraft {
    var text = ""
}

private struct DesignImplementationContextEditor: View {
    @Bindable var draft: DesignImplementationDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("ADDITIONAL CONTEXT", style: .field)
            AppTextEditor(
                text: $draft.text,
                placeholder: "For example: use the second checkout option and keep the current navigation.",
                minHeight: 96)
                .frame(height: 96)
        }
        .padding(.top, 6)
    }
}

struct DesignReferenceView: View {
    @Environment(ProjectStore.self) private var store

    let sessionID: UUID

    @State private var canvas = DesignCanvas()
    @State private var designWindow = DesignWindow()

    var body: some View {
        if let session = store.session(sessionID),
           let directory = store.implementationDesignDirectory(for: session) {
            VStack(spacing: 0) {
                DesignCanvasBar(canvas: canvas) {
                    Image(systemName: "paintbrush.pointed.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("APPROVED DESIGN")
                        .font(.mono(10, .semibold))
                        .kerning(1)
                    if let title = revisionTitle(session) {
                        MonoChip(text: title.uppercased(), size: 8.5, tint: Theme.accent)
                    }
                } tools: {
                    if let sourceID = session.sourceDesignSessionID,
                       store.session(sourceID) != nil {
                        ActionButton(title: "Edit Design", tone: .outlined,
                                     height: 28, size: 11, icon: "arrow.up.right") {
                            store.selectSession(sourceID)
                        }
                    }

                    if canvas.revision != nil {
                        ActionButton(title: "Full Screen",
                                     tone: designWindow.isOpen ? .sunken : .outlined,
                                     height: 28, size: 11, icon: "macwindow") {
                            openDesignWindow(session, directory: directory)
                        }
                        .appTooltip(designWindow.isOpen
                            ? "Bring design window to front"
                            : "Open design in a separate window")
                    }
                }

                if let revision = canvas.revision, let url = canvas.screenURL(in: directory) {
                    DesignWebView(
                        url: url,
                        readAccessURL: directory,
                        screen: canvas.selectedScreen,
                        revision: revision,
                        reloadGeneration: canvas.reloadGeneration,
                        selectionEnabled: false,
                        snapshotRequest: nil,
                        onSelection: { _ in },
                        onSnapshot: { _, _ in })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.white)
                } else {
                    unavailable(session)
                }
            }
            .task(id: directory.path) { await canvas.watch(directory) }
            .onDisappear { designWindow.close() }
        } else {
            unavailable(store.session(sessionID))
        }
    }

    private func openDesignWindow(_ session: ChatSession, directory: URL) {
        designWindow.show(
            title: session.title,
            content: DesignWindowView(canvas: canvas,
                                      directory: directory,
                                      label: revisionTitle(session) ?? "Approved design",
                                      onClose: { designWindow.close() }))
    }

    // Whether there is a way out of this depends on the Design the session was handed:
    // one that is still around can be opened and handed off again, while a deleted one
    // leaves nothing to point at, so saying otherwise would send the reader hunting.
    @ViewBuilder private func unavailable(_ session: ChatSession?) -> some View {
        let title = "The Design reference is unavailable"
        if let sourceID = session?.sourceDesignSessionID, store.session(sourceID) != nil {
            PaneMessage(icon: "paintbrush.pointed", title: title,
                        detail: "Return to the source Design and create another handoff.") {
                ActionButton(title: "Open Design", tone: .outlined, icon: "arrow.up.right") {
                    store.selectSession(sourceID)
                }
                .padding(.top, 4)
            }
        } else {
            PaneMessage(
                icon: "paintbrush.pointed", title: title,
                detail: "The Design session it came from has been deleted, so there is nothing left to show here. The work in this session is unaffected.")
        }
    }

    private func revisionTitle(_ session: ChatSession) -> String? {
        if let revisionID = session.handedOffDesignRevisionID,
           let sourceSessionID = session.sourceDesignSessionID,
           let sourceSession = store.session(sourceSessionID),
           let revision = sourceSession.designRevisions.first(where: { $0.id == revisionID }) {
            return revision.title
        }
        if let revision = store.approvedDesignRevision(for: session) { return revision.title }
        return session.handedOffDesignRevisionID == nil ? nil : "Approved"
    }
}

// What a canvas is showing: the design's files on disk, the screens they make up, and
// which one is on view. The agent writes those files behind the app's back and nothing
// announces the change, so whichever pane shows a design keeps one of these and polls it.
@MainActor
@Observable
final class DesignCanvas {
    private(set) var revision: DesignArtifactRevision?
    private(set) var manifest = DesignManifest.singleScreen
    private(set) var selectedScreenID = DesignScreen.canvas.id
    // Counted up to load the same files again.
    private(set) var reloadGeneration = 0

    var selectedScreen: DesignScreen? {
        manifest.screens.first { $0.id == selectedScreenID } ?? manifest.screens.first
    }

    func screenURL(in directory: URL) -> URL? {
        selectedScreen.flatMap { DesignManifest.safeURL(for: $0, in: directory) }
    }

    var screenMenu: [MenuEntry] {
        manifest.screens.map { screen in
            .item(screen.title, icon: "rectangle", checked: screen.id == selectedScreenID,
                  subtitle: screen.path) { self.selectedScreenID = screen.id }
        }
    }

    func reload() { reloadGeneration += 1 }

    // Runs until it is cancelled, so it belongs in a task keyed on the directory.
    func watch(_ directory: URL) async {
        while !Task.isCancelled {
            let next = DesignArtifactRevision.read(directory)
            if next != revision { revision = next }
            let nextManifest = DesignManifest.read(from: directory)
            if nextManifest != manifest {
                manifest = nextManifest
                if !manifest.screens.contains(where: { $0.id == selectedScreenID }) {
                    selectedScreenID = manifest.screens.first?.id ?? DesignScreen.canvas.id
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
        }
    }
}

// The bar over a canvas: what the pane calls it on the left, and on the right the screen
// picker when the design has more than one screen, the pane's own tools, and a reload.
struct DesignCanvasBar<Leading: View, Tools: View>: View {
    let canvas: DesignCanvas
    @ViewBuilder let leading: Leading
    @ViewBuilder let tools: Tools

    var body: some View {
        HStack(spacing: 10) {
            leading
            Spacer(minLength: 10)
            if canvas.manifest.screens.count > 1 {
                OptionMenu(value: canvas.selectedScreen?.title ?? "Screen", matchWidth: false) {
                    canvas.screenMenu
                }
                .fixedSize()
            }
            tools
            if canvas.revision != nil {
                GlyphButton(icon: "arrow.clockwise", side: 28, tint: Theme.accent) {
                    canvas.reload()
                }
                .appTooltip("Reload canvas")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: DesignSplitLayout.barHeight)
        .background(Theme.card)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

enum DesignSplitLayout {
    static let defaultConversationWidth: CGFloat = 300
    static let minimumConversationWidth: CGFloat = 280
    static let minimumCanvasWidth: CGFloat = 320
    static let dividerWidth: CGFloat = 1
    static let handleWidth: CGFloat = 9
    // The conversation folded down to its rail, which leaves the canvas the pane.
    static let collapsedWidth: CGFloat = 44
    // The conversation header and the canvas bar share one height so they read as one strip.
    static let barHeight: CGFloat = 42

    static func conversationWidth(_ proposedWidth: CGFloat,
                                  availableWidth: CGFloat) -> CGFloat {
        let paneWidth = max(0, availableWidth - dividerWidth)
        let halfWidth = paneWidth / 2
        let minimum = min(minimumConversationWidth, halfWidth)
        let maximum = max(minimum, paneWidth - min(minimumCanvasWidth, halfWidth))
        return min(max(proposedWidth, minimum), maximum)
    }
}

struct DesignElementSelection: Equatable {
    let selector: String
    let tag: String
    let text: String
    let rect: CGRect
}

struct DesignSnapshotRequest: Equatable {
    enum Purpose: Equatable { case handoff, selection }

    let id = UUID()
    let purpose: Purpose
    var rect: CGRect?
    var additionalContext: String?
}
