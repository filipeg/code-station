import AppKit
import SwiftUI

// A Design conversation reads as a list of versions on the left, each one the prompt that
// made it beside a thumbnail of what it left on the canvas, with the composer under the
// list, and the live canvas on the right. Every turn that changes the canvas is saved as a
// version on its own, so going back is picking a card rather than a menu entry.
struct DesignView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.textScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let sessionID: UUID
    var onOpenImplementation: (() -> Void)? = nil

    @State private var canvas = DesignCanvas()
    @State private var composerFocused = false
    @State private var conversationWidth = DesignSplitLayout.defaultConversationWidth
    @State private var dragStartConversationWidth: CGFloat?
    @State private var versionsCollapsed = false
    // Nil while the live canvas is on view.
    @State private var displayedRevisionID: UUID?
    // The saved version whose files the live canvas holds right now, if any.
    @State private var liveRevisionID: UUID?
    @State private var comparing = false
    // Cards whose fold differs from the default: the newest turn starts open, the rest
    // start folded.
    @State private var toggledTurns: Set<UUID> = []
    @State private var selectionEnabled = false
    @State private var snapshotRequest: DesignSnapshotRequest?
    @State private var preparingHandoff = false
    @State private var savingVersion = false
    @State private var waitNoticeDismissed = false
    @State private var designWindow = DesignWindow()

    var body: some View {
        if let session = store.session(sessionID),
           let artifactURL = store.designArtifactURL(for: session) {
            let liveDirectory = artifactURL.deletingLastPathComponent()
            let displayedDirectory = displayedDirectory(for: session, live: liveDirectory)
            let turns = DesignTurns.build(messages: session.messages,
                                          revisions: session.designRevisions)
            GeometryReader { geometry in
                let width = versionsCollapsed
                    ? DesignSplitLayout.collapsedWidth
                    : DesignSplitLayout.conversationWidth(
                        conversationWidth, availableWidth: geometry.size.width)

                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        Group {
                            if versionsCollapsed {
                                versionsRail(session)
                            } else {
                                versionsColumn(session, turns: turns, width: width)
                            }
                        }
                        .frame(width: width)
                        .clipped()
                        Divider().overlay(Theme.hairline)
                        canvasColumn(session, directory: displayedDirectory,
                                     liveDirectory: liveDirectory)
                    }

                    if !versionsCollapsed {
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
            .task(id: displayedDirectory.path) { await canvas.watch(displayedDirectory) }
            .task(id: versionCheck(session)) {
                await checkVersions(liveDirectory: liveDirectory)
            }
            // Sending a prompt puts the live canvas back on view, since that is where
            // the turn draws.
            .onChange(of: runner.state(sessionID).isBusy) { _, busy in
                if busy {
                    displayedRevisionID = nil
                    comparing = false
                }
            }
        } else {
            PaneMessage(icon: "paintbrush.pointed",
                        title: "This Design session is gone",
                        detail: "Choose another session from the sidebar.")
        }
    }

    private func displayedDirectory(for session: ChatSession, live: URL) -> URL {
        guard let displayedRevision = displayedRevision(in: session) else { return live }
        return DesignArtifacts.materialsDirectory(displayedRevision, designDirectory: live)
    }

    private func displayedRevision(in session: ChatSession) -> DesignRevision? {
        guard let displayedRevisionID else { return nil }
        return session.designRevisions.first { $0.id == displayedRevisionID }
    }

    private var displayedRevision: DesignRevision? {
        store.session(sessionID).flatMap(displayedRevision(in:))
    }

    private var liveRevision: DesignRevision? {
        guard let liveRevisionID, let session = store.session(sessionID) else { return nil }
        return session.designRevisions.first { $0.id == liveRevisionID }
    }

    // The version the canvas is showing: the one picked, or the one the live files match.
    private var shownRevision: DesignRevision? { displayedRevision ?? liveRevision }

    private var latestPromptID: UUID? {
        store.session(sessionID)?.messages.last(where: { $0.role == .user })?.id
    }

    // MARK: - Versions

    private func versionsColumn(_ session: ChatSession, turns: [DesignTurn],
                                width: CGFloat) -> some View {
        let projectPath = store.workingDirectory(for: session) ?? ""
        let versionCount = session.designRevisions.count
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Versions")
                    .font(.system(size: 12, weight: .semibold))
                if versionCount > 0 {
                    Text("\(versionCount)")
                        .font(.mono(10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                compareButton(session)
                GlyphButton(icon: "sidebar.left", side: 26) { versionsCollapsed = true }
                    .appTooltip("Hide versions")
                    .accessibilityLabel("Hide versions")
            }
            .padding(.horizontal, 12)
            .frame(height: DesignSplitLayout.barHeight)
            .background(Theme.card)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(turns) { turn in
                            versionCard(turn, session: session,
                                        isLatest: turn.id == turns.last?.id,
                                        projectPath: projectPath,
                                        width: width)
                        }
                        Color.clear.frame(height: 1).id("design-versions-bottom")
                    }
                    .padding(10)
                }
                .defaultScrollAnchor(.bottom)
                // Anything new - a turn, streamed text, a call, a change of state - sends
                // the list to its end, where the newest card is.
                .onChange(of: transcriptShape(session)) {
                    proxy.scrollTo("design-versions-bottom", anchor: .bottom)
                }
            }

            Divider().overlay(Theme.hairline)
            turnNotices(session)
            designComposer(session)
        }
        .background(Theme.background)
    }

    private func versionsRail(_ session: ChatSession) -> some View {
        VStack(spacing: 10) {
            GlyphButton(icon: "sidebar.left", side: 26) { versionsCollapsed = false }
                .appTooltip("Show versions")
                .accessibilityLabel("Show versions")
            if !session.designRevisions.isEmpty {
                Text("\(session.designRevisions.count)")
                    .font(.mono(10.5))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(counted(session.designRevisions.count, "version"))
            }
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

    private func compareButton(_ session: ChatSession) -> some View {
        let available = comparisonPair(session) != nil
        return GlyphButton(icon: "rectangle.split.2x1", side: 26,
                           active: comparing && available, tint: Theme.accent) {
            comparing.toggle()
        }
        .disabled(!available)
        .opacity(available ? 1 : 0.4)
        .appTooltip(available ? "Compare with the version before it"
                              : "Compare needs two versions")
        .accessibilityLabel("Compare versions")
    }

    // The version on view and the one saved before it, oldest first.
    private func comparisonPair(_ session: ChatSession) -> (DesignRevision, DesignRevision)? {
        let revisions = session.designRevisions.sorted { $0.number < $1.number }
        guard let shown = shownRevision ?? revisions.last,
              let index = revisions.firstIndex(where: { $0.id == shown.id }),
              index > 0 else { return nil }
        return (revisions[index - 1], shown)
    }

    private func isSelected(_ turn: DesignTurn, isLatest: Bool) -> Bool {
        if let revision = turn.revision, let shown = shownRevision {
            return revision.id == shown.id
        }
        // While the live canvas matches no version, it belongs to the newest turn.
        return shownRevision == nil && isLatest
    }

    private func versionCard(_ turn: DesignTurn, session: ChatSession, isLatest: Bool,
                             projectPath: String, width: CGFloat) -> some View {
        let open = toggledTurns.contains(turn.id) != isLatest
        let selected = isSelected(turn, isLatest: isLatest)
        let working = isLatest && runner.state(sessionID).isBusy
        let work = turn.work.filter { !$0.isEmpty }
        let title = turn.title
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Button { choose(turn, open: open) } label: {
                    HStack(alignment: .top, spacing: 9) {
                        thumbnail(turn, session: session)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            cardMeta(turn, session: session, working: working)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(turn.revision.map { "\($0.title): \(title)" } ?? title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityHint(turn.revision == nil ? "Shows the agent's work"
                                                        : "Puts this version on the canvas")

                if !work.isEmpty {
                    Button { toggleFold(turn) } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(open ? 180 : 0))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .appTooltip(open ? "Hide the agent's work" : "Show the agent's work")
                    .accessibilityLabel(open ? "Hide the agent's work" : "Show the agent's work")
                }
            }

            if open, !work.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(work) { message in
                        MessageView(message: message,
                                    projectPath: projectPath,
                                    textScale: textScale,
                                    availableWidth: width - 40)
                            .equatable()
                            .environment(\.runningAgents, runner.runningAgents(sessionID))
                            .environment(\.activeTranscriptTools, runner.runningTools(sessionID))
                    }
                }
                .transition(.fold)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        // Folding work fades out while the card shrinks, so it must not spill past the card.
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected ? Theme.accent : Theme.hairline,
                          lineWidth: selected ? 1.5 : 1))
    }

    @ViewBuilder
    private func thumbnail(_ turn: DesignTurn, session: ChatSession) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        Group {
            if let revision = turn.revision {
                DesignThumbnail(url: DesignArtifacts.previewURL(
                    revision, designDirectory: store.designDirectory(for: session)))
            } else {
                Image(systemName: "text.bubble")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.sunken)
            }
        }
        .frame(width: 46, height: 34)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.hairline))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func cardMeta(_ turn: DesignTurn, session: ChatSession, working: Bool) -> some View {
        if working {
            designStatus(session)
        } else if let revision = turn.revision {
            Text("Version \(revision.number), \(age(revision.createdAt))")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        } else {
            Text("No canvas change")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    private func age(_ date: Date) -> String {
        let short = RelativeTime.short(date)
        return short == "now" ? "just now" : "\(short) ago"
    }

    // Picking a version puts it on the canvas; picking the one already there folds or
    // unfolds its work instead. A card without a version only folds.
    private func choose(_ turn: DesignTurn, open: Bool) {
        guard let revision = turn.revision else {
            toggleFold(turn)
            return
        }
        if shownRevision?.id == revision.id {
            toggleFold(turn)
            return
        }
        displayedRevisionID = revision.id == liveRevisionID ? nil : revision.id
        comparing = false
        selectionEnabled = false
    }

    private func toggleFold(_ turn: DesignTurn) {
        withAnimation(reduceMotion ? nil : Motion.reveal) {
            if toggledTurns.contains(turn.id) { toggledTurns.remove(turn.id) }
            else { toggledTurns.insert(turn.id) }
        }
    }

    // What the agent is doing, on the newest card. A held-open turn looks exactly like a
    // working one from the outside, so a wait names the task keeping it open instead of
    // going on claiming the canvas is being worked on. Once the wait has gone stale the
    // line drops the live colour too: nothing is coming back from that task, and the pane
    // has to agree with the NEEDS YOU the header is already showing.
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
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(stale ? Theme.attentionText : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(RelativeTime.duration(since: waitingSince))
                        .font(.system(size: 10.5))
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
                    .font(.system(size: 10.5, weight: .medium))
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
            .accessibilityLabel("Resize Design versions")
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
                        onSend: branchIfNeeded,
                        above: {
                            ScrollView(.horizontal, showsIndicators: false) {
                                SessionRunSettingsControls(sessionID: sessionID)
                            }
                            let queued = runner.queued(sessionID).count
                            if queued > 0 {
                                Text(counted(queued, "revision") + " queued")
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
        if runner.state(sessionID).isBusy { return "Queue the next revision…" }
        if let displayed = displayedRevision(in: session), displayed.id != liveRevisionID {
            return "Start from v\(displayed.number)…"
        }
        if let live = liveRevision { return "Refine v\(live.number)…" }
        return session.messages.isEmpty ? "Describe what to design…" : "Refine this design…"
    }

    // A prompt sent while an older version is on view starts from that version: its files
    // go back on the live canvas before the turn begins. While a turn runs the prompt
    // only queues, and rewriting the canvas under the agent would wreck its work.
    private func branchIfNeeded() {
        defer {
            displayedRevisionID = nil
            comparing = false
        }
        guard !runner.state(sessionID).isBusy,
              let revision = displayedRevision, revision.id != liveRevisionID else { return }
        switch store.restoreDesignRevision(revision.id, for: sessionID) {
        case .success:
            liveRevisionID = revision.id
            store.append(ChatMessage(role: .system, text: "Started from \(revision.title)."),
                         to: sessionID)
        case .failure(let failure):
            dialogs.show(.notice("Could not start from \(revision.title)",
                                 message: failure.message))
        }
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

    private func canvasColumn(_ session: ChatSession, directory: URL,
                              liveDirectory: URL) -> some View {
        let implementation = store.implementationSessions(for: session.id).last
        let needsImplementationUpdate = implementation.map {
            designNeedsUpdate(session, implementation: $0, liveDirectory: liveDirectory)
        } ?? false
        let busy = runner.state(sessionID).isBusy
        let pair = comparing ? comparisonPair(session) : nil
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
                if let pair {
                    MonoChip(text: "V\(pair.0.number) AND V\(pair.1.number)", size: 8.5,
                             tint: Theme.accent)
                } else if let displayed = displayedRevision {
                    MonoChip(text: "VIEWING V\(displayed.number)", size: 8.5, tint: Theme.accent)
                }
            } tools: {
                if canvas.revision != nil {
                    if displayedRevision == nil, pair == nil {
                        GlyphButton(icon: selectionEnabled ? "scope" : "cursorarrow", side: 28,
                                    active: selectionEnabled, tint: Theme.accent) {
                            selectionEnabled.toggle()
                        }
                        .appTooltip(selectionEnabled
                            ? "Stop selecting canvas elements"
                            : "Select an element to refine")
                        .accessibilityLabel("Select an element to refine")
                    }

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

                        if needsImplementationUpdate || displayedRevision != nil {
                            ActionButton(
                                title: preparingHandoff ? "Preparing…" : implementTitle("Update build"),
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
                        ActionButton(title: preparingHandoff ? "Preparing…" : implementTitle("Implement"),
                                     tone: .green, height: 28, size: 11,
                                     icon: preparingHandoff ? "hourglass" : "hammer.fill") {
                            showImplementationDialog()
                        }
                        .disabled(preparingHandoff || busy)
                    }
                }
            }

            ZStack(alignment: .top) {
                canvasContent(session, directory: directory, pair: pair,
                              liveDirectory: liveDirectory, busy: busy)
                if busy, displayedRevision == nil, canvas.revision != nil {
                    buildingBadge(session)
                        .padding(.top, 10)
                }
            }

            // The folded versions rail is too narrow for the composer, so it moves here.
            if versionsCollapsed {
                Divider().overlay(Theme.hairline)
                turnNotices(session)
                designComposer(session)
            }
        }
    }

    private func implementTitle(_ verb: String) -> String {
        shownRevision.map { "\(verb) v\($0.number)" } ?? verb
    }

    private func buildingBadge(_ session: ChatSession) -> some View {
        let next = (session.designRevisions.map(\.number).max() ?? 0) + 1
        return HStack(spacing: 6) {
            StateLight(tone: .running, size: 6)
            Text("Building v\(next)")
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().strokeBorder(Theme.border))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func canvasContent(_ session: ChatSession, directory: URL,
                               pair: (DesignRevision, DesignRevision)?,
                               liveDirectory: URL, busy: Bool) -> some View {
        if let pair {
            let older = DesignArtifacts.materialsDirectory(pair.0, designDirectory: liveDirectory)
            let newer = DesignArtifacts.materialsDirectory(pair.1, designDirectory: liveDirectory)
            HStack(spacing: 1) {
                comparedPreview(pair.0, directory: older)
                comparedPreview(pair.1, directory: newer)
            }
        } else if let revision = canvas.revision, let url = canvas.screenURL(in: directory) {
            // The agent cannot see the canvas it draws into, so the canvas tells it how
            // much room there is. Only the live canvas reports: an older version is a
            // way of looking back, not a width the agent has to work at.
            canvasPreview(url, directory: directory, revision: revision,
                          selectionEnabled: displayedRevision == nil && selectionEnabled,
                          onViewport: displayedRevision == nil
                              ? { runner.recordCanvasWidth($0, for: sessionID) } : nil)
        } else if busy {
            PaneMessage(icon: "paintbrush.pointed",
                        title: "Building the first version",
                        detail: "It appears here as soon as \(session.agent.title) writes it.")
                .background(Theme.sunken)
        } else {
            PaneMessage(icon: "rectangle.on.rectangle.angled",
                        title: "Your design appears here",
                        detail: versionsCollapsed
                            ? "Describe what to design in the prompt below."
                            : "Describe what to design in the prompt at the bottom of the Versions panel.")
                .background(Theme.sunken)
        }
    }

    @ViewBuilder
    private func comparedPreview(_ revision: DesignRevision, directory: URL) -> some View {
        if let files = DesignArtifactRevision.read(directory),
           let url = canvas.screenURL(in: directory) {
            labelledPreview(revision.title.uppercased(), url: url, directory: directory,
                            revision: files, selectionEnabled: false)
        } else {
            PaneMessage(icon: "exclamationmark.triangle",
                        title: "\(revision.title) is missing",
                        detail: "Its saved files could not be read.")
                .background(Theme.sunken)
        }
    }

    private func openDesignWindow(_ session: ChatSession, directory: URL) {
        designWindow.show(
            title: session.title,
            content: DesignWindowView(canvas: canvas,
                                      directory: directory,
                                      label: shownRevision?.title ?? "Canvas",
                                      onClose: { designWindow.close() }))
    }

    private func labelledPreview(_ label: String, url: URL, directory: URL,
                                 revision: DesignArtifactRevision,
                                 selectionEnabled: Bool) -> some View {
        VStack(spacing: 0) {
            Text(label)
                .font(.mono(9.5, .semibold))
                .kerning(0.8)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Theme.sunken)
            canvasPreview(url, directory: directory, revision: revision,
                          selectionEnabled: selectionEnabled)
        }
    }

    private func canvasPreview(_ url: URL, directory: URL,
                               revision: DesignArtifactRevision,
                               selectionEnabled: Bool,
                               onViewport: ((Double) -> Void)? = nil) -> some View {
        DesignWebView(url: url,
                      readAccessURL: directory,
                      screen: canvas.selectedScreen,
                      revision: revision,
                      reloadGeneration: canvas.reloadGeneration,
                      selectionEnabled: selectionEnabled,
                      snapshotRequest: snapshotRequest,
                      onSelection: selectElement,
                      onSnapshot: receiveSnapshot,
                      onViewport: onViewport)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
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

    // MARK: - Saving versions

    // Everything that can change whether the live canvas still needs saving. The check
    // runs again whenever one of these moves.
    private struct VersionCheck: Equatable {
        var busy: Bool
        var canvas: DesignArtifactRevision?
        var revisions: [UUID]
        var displayed: UUID?
        var comparing: Bool
        var snapshotPending: Bool
        var saving: Bool
    }

    private func versionCheck(_ session: ChatSession) -> VersionCheck {
        VersionCheck(busy: runner.state(sessionID).isBusy,
                     canvas: canvas.revision,
                     revisions: session.designRevisions.map(\.id),
                     displayed: displayedRevisionID,
                     comparing: comparing,
                     snapshotPending: snapshotRequest != nil,
                     saving: savingVersion || preparingHandoff)
    }

    // Saves the live canvas as a version once a turn has left it in a state no version
    // holds yet. Turns that change no files, such as a question or a plan, save nothing.
    // The thumbnail is a picture of the canvas, so it waits until the live canvas is the
    // one on view and has had a moment to load what the turn last wrote.
    private func checkVersions(liveDirectory: URL) async {
        guard let session = store.session(sessionID) else { return }
        liveRevisionID = session.designRevisions
            .sorted { $0.number > $1.number }
            .first { DesignArtifacts.matchesLive($0, designDirectory: liveDirectory) }?.id

        let check = versionCheck(session)
        guard liveRevisionID == nil, !check.busy, !check.saving, !check.snapshotPending,
              check.displayed == nil, !check.comparing,
              let shown = check.canvas, shown == DesignArtifactRevision.read(liveDirectory),
              canvas.screenURL(in: liveDirectory) != nil else { return }
        do {
            try await Task.sleep(for: .milliseconds(900))
        } catch {
            return
        }
        snapshotRequest = DesignSnapshotRequest(purpose: .revision)
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
        case .revision:
            savingVersion = true
            Task { await saveVersion(screenshot: image.flatMap(DesignArtifacts.pngData)) }
        }
    }

    private func saveVersion(screenshot: Data?) async {
        defer { savingVersion = false }
        guard let session = store.session(sessionID) else { return }
        let source = await DesignHandoffLifecycle.sourceRevisions(for: session, store: store)
        switch store.saveDesignRevision(sessionID, screenshot: screenshot,
                                        sourceRevisions: source, promptID: latestPromptID) {
        case .success(let revision):
            liveRevisionID = revision.id
        case .failure(let failure):
            dialogs.show(.notice("Could not save the Design version", message: failure.message))
        }
    }

    // MARK: - Implementation

    private func showImplementationDialog() {
        let draft = DesignImplementationDraft()
        let title = shownRevision.map { "Implement \($0.title)?" } ?? "Implement this Design?"
        dialogs.show(Dialog(
            title: title,
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

    // Hands over the version on view. One already saved is approved as it is; a live
    // canvas no version holds yet is saved first, with a fresh picture of it.
    private func implement(additionalContext: String? = nil) {
        if let revision = shownRevision {
            preparingHandoff = true
            switch store.approveDesignRevision(revision.id, for: sessionID) {
            case .success(let approved):
                handOver(approved, additionalContext: additionalContext)
            case .failure(let failure):
                preparingHandoff = false
                dialogs.show(.notice("Could not prepare the Design", message: failure.message))
            }
            return
        }
        guard canvas.revision != nil else { return }
        preparingHandoff = true
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
            liveRevisionID = revision.id
            handOver(revision, additionalContext: additionalContext)
        }
    }

    private func handOver(_ revision: DesignRevision, additionalContext: String?) {
        preparingHandoff = false
        if let implementation = store.implementationSessions(for: sessionID).last {
            switch DesignHandoffLifecycle.sendLatestDesign(
                to: implementation.id, store: store, runner: runner) {
            case .success:
                store.append(ChatMessage(
                    role: .system,
                    text: "Sent \(revision.title) to Build."),
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
                                   liveDirectory: URL) -> Bool {
        if store.designHasUpdated(for: implementation) { return true }
        guard let revisionID = implementation.handedOffDesignRevisionID,
              let revision = design.designRevisions.first(where: { $0.id == revisionID }) else {
            return true
        }
        let handedOff = DesignArtifacts.materialsDirectory(
            revision, designDirectory: store.designDirectory(for: design))
        return DesignArtifactRevision.read(liveDirectory)
            != DesignArtifactRevision.read(handedOff)
    }

    private func openImplementation(_ implementation: ChatSession) {
        if let onOpenImplementation {
            onOpenImplementation()
        } else {
            store.selectSession(implementation.id)
        }
    }
}

// The picture a version saved of its canvas. Read off the main thread, since a full
// canvas screenshot can run to a few megabytes.
private struct DesignThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Theme.sunken
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            let url = url
            let data = await Task.detached { try? Data(contentsOf: url) }.value
            image = data.flatMap(NSImage.init(data:))
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
    // The versions column folded down to its rail, which leaves the canvas the pane.
    static let collapsedWidth: CGFloat = 44
    // The versions header and the canvas bar share one height so they read as one strip.
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
    enum Purpose: Equatable { case handoff, revision, selection }

    let id = UUID()
    let purpose: Purpose
    var rect: CGRect?
    var additionalContext: String?
}
