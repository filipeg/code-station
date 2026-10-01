import SwiftUI

struct HomeSessionInspector: View {
    let live: HomeLive
    let hasChanges: Bool
    let changedFiles: Int?
    let recap: SessionRecap?
    let recapping: Bool
    let canRecap: Bool
    let offersManualRecap: Bool
    let onRecap: () -> Void
    let onOpen: (SessionDestination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    StateLight(tone: live.tone)
                    Text(live.status).font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(live.tone == .needsYou ? Theme.attentionText : live.tone.colour)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Capsule().fill(live.tone.colour.opacity(0.1)))
                Spacer(minLength: 0)
                Text(RelativeTime.short(live.session.lastActivity))
                    .font(.mono(10)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    ProjectDot(tint: live.tint, size: 6)
                    Text(live.containerName).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(live.session.title)
                    .font(.serif(24, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(live.session.agent.title) · \(live.location)")
                    .font(.mono(10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let recap, live.permission == nil {
                HomeRecap(recap: recap)
            }
            if live.permission != nil || recap == nil || live.tone != .idle && !live.finished {
                Text(live.activity)
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Text(changedFiles.map { counted($0, "uncommitted file") } ?? "Checking files…")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                DiffPair(added: live.session.summary.added, removed: live.session.summary.removed, size: 11)
                    .appTooltip("Lines written during this session")
            }
            FlowRow(spacing: 10) {
                let action = live.primaryAction(hasChanges: hasChanges)
                ActionButton(title: action.title, tone: .green, size: 12) { onOpen(action.destination) }
                InlineLink(title: live.destination == .design ? "Design conversation" : "Conversation", size: 11.5) { onOpen(live.destination) }
                if hasChanges && action.destination != .changes {
                    InlineLink(title: "Changes", size: 11.5) { onOpen(.changes) }
                }
            }
            if live.permission == nil, recap == nil {
                if recapping {
                    Label("Generating recap…", systemImage: "sparkles")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else if offersManualRecap, canRecap {
                    InlineLink(title: "Generate recap", size: 11.5, action: onRecap)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
        .surface(Theme.card, cornerRadius: 14, border: live.tone.ring)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected session: \(live.session.title)")
    }
}

struct HomeAccountUsage: View {
    @State private var codex: CodexAgentInfo?

    var body: some View {
        Group {
            if let codex, codex.account != nil {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Codex usage").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        InlineLink(title: "Refresh", size: 10.5, action: codex.refresh)
                            .disabled(codex.isRefreshingUsage)
                    }
                    if codex.isRefreshingUsage {
                        Text("Checking account limits…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    } else if let usage = codex.usage {
                        ForEach(usage.windows) { window in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(window.title)
                                    Spacer()
                                    Text("\(window.usedPercent)% used")
                                }
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                Meter(fraction: window.usedFraction,
                                      colour: window.usedPercent >= 90 ? Theme.deletion
                                        : window.usedPercent >= 75 ? Theme.attention : Theme.addition,
                                      height: 6)
                                    .accessibilityLabel("\(window.title), \(window.usedPercent) percent used")
                                if let reset = window.resetsAt {
                                    Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("Checked \(usage.checkedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        Text("Account limits are unavailable. Try refreshing.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .surface(Theme.accent.opacity(0.06), cornerRadius: 12)
            }
        }
        .task {
            if codex == nil { codex = CodexAgentInfo() }
        }
    }
}
