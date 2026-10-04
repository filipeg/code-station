import SwiftUI

// The way out of a wait that has no end of its own. A held-open turn is correct behaviour
// and usually short, but nothing bounds it: a dev server or a watcher keeps the turn alive
// for as long as it runs, and from the outside that is indistinguishable from a hang. Past
// a few minutes the wait names itself and offers the only two answers there are.
struct WaitingNotice: View {
    @Environment(\.textScale) private var textScale

    let since: Date
    let tasks: [BackgroundTask]
    let agentTitle: String
    // Looked up rather than passed in already resolved: the answer costs a walk back
    // through the transcript, and the card is only on screen after minutes of waiting.
    let command: (BackgroundTask) -> String?
    let onKeepWaiting: () -> Void
    let onEnd: () -> Void

    // Short waits are ordinary - a build, a test run - and a card under every one of them
    // would be noise. This is about the ones that are not going to end on their own.
    private static let showAfter: TimeInterval = 3 * 60

    var body: some View {
        // Five seconds is fine for something that appears once after minutes, and it keeps
        // the transcript from redrawing every second for a card that is not counting.
        TimelineView(.periodic(from: .now, by: 5)) { context in
            if context.date.timeIntervalSince(since) >= Self.showAfter {
                card
            }
        }
    }

    private var title: String {
        tasks.count == 1 ? "Waiting on a background task" : "Waiting on background tasks"
    }

    private var consequence: String {
        tasks.count == 1 ? "Ending the turn also stops this task." : "Ending the turn also stops these tasks."
    }

    private var card: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        heading
                        Spacer(minLength: 12)
                        elapsed.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        heading
                        elapsed.padding(.leading, 52)
                    }
                }
                Text("\(agentTitle) has replied. The turn stays open so it can resume when "
                     + (tasks.count == 1 ? "the task finishes." : "the tasks finish."))
                    .font(.system(size: 14 * textScale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(tasks) { task in
                    WaitingTaskRow(task: task, command: command(task))
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) {
                        stopConsequence.fixedSize()
                        Spacer(minLength: 0)
                        actions
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        stopConsequence
                        HStack {
                            Spacer(minLength: 0)
                            actions
                        }
                    }
                }
            }
            .padding(24)
            .cardSurface(cornerRadius: 14)
            Label("You can also send a message to continue in this turn.", systemImage: "bubble.left")
                .font(.system(size: 12 * textScale))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { AccessibilityNotification.Announcement(title).post() }
    }

    private var heading: some View {
        HStack(spacing: 14) {
            Image(systemName: "clock")
                .font(.system(size: 20 * textScale))
                .foregroundStyle(Theme.attentionText)
                .frame(width: 38 * textScale, height: 38 * textScale)
                .background(Theme.attentionText.opacity(0.1), in: Circle())
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 19 * textScale, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var elapsed: some View {
        Text("Last reply \(RelativeTime.duration(since: since)) ago")
            .font(.system(size: 12 * textScale))
            .foregroundStyle(.secondary)
    }

    private var stopConsequence: some View {
        Text(consequence)
            .font(.system(size: 12 * textScale))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            ActionButton(title: "End turn", tone: .outlined,
                         height: 36 * textScale, size: 12 * textScale, action: onEnd)
                .accessibilityHint(consequence)
            ActionButton(title: "Keep waiting", tone: .dark,
                         height: 36 * textScale, size: 12 * textScale, action: onKeepWaiting)
                .accessibilityHint("Dismiss this notice for the current wait.")
        }
    }
}

private struct WaitingTaskRow: View {
    @Environment(\.textScale) private var textScale
    @State private var expanded = false
    @FocusState private var disclosureFocused: Bool
    let task: BackgroundTask
    let command: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(task.label)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Circle().fill(Theme.attentionText).frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text("Pending")
                }
                .font(.system(size: 11 * textScale))
                .foregroundStyle(Theme.attentionText)
                .fixedSize()
            }
            if let command {
                VStack(alignment: .leading, spacing: 12) {
                    Button { expanded.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9 * textScale, weight: .semibold))
                            Text(expanded ? "Hide command" : "Show command")
                        }
                        .font(.system(size: 12 * textScale))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($disclosureFocused)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(disclosureFocused ? Theme.accent : .clear, lineWidth: 2))
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                    .accessibilityHint("Command for \(task.label)")
                    if expanded {
                        Text(command)
                            .font(.mono(11 * textScale))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .cardSurface(cornerRadius: 6)
                    }
                }
                .padding(.leading, 26)
            }
        }
        .font(.system(size: 14 * textScale))
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 9))
    }
}
