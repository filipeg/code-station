import Foundation

// One card in the Design versions column: a prompt, the work the agent did for it, and
// the version that work left on the canvas. A turn that changed nothing on the canvas,
// such as a question or a plan, has no version and reads as text only.
struct DesignTurn: Identifiable, Equatable {
    let id: UUID
    var prompt: ChatMessage?
    var work: [ChatMessage] = []
    var revision: DesignRevision?

    // The prompt on one line, which the card clamps. A card with no prompt is a version
    // saved before turns kept theirs, so it goes by the version's name.
    var title: String {
        if let prompt, !prompt.text.isBlank {
            return prompt.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return revision?.title ?? "Design"
    }

    var date: Date { prompt?.date ?? work.first?.date ?? revision?.createdAt ?? .distantPast }
}

enum DesignTurns {
    // Splits the conversation at each prompt and pairs every turn with the version it
    // made. A version made by a turn names its prompt; older versions saved by hand do
    // not, so they join the turn that was running when they were saved. A version that
    // still finds no free turn gets a card of its own, so no saved version is ever hidden.
    static func build(messages: [ChatMessage], revisions: [DesignRevision]) -> [DesignTurn] {
        var turns: [DesignTurn] = []
        for message in messages {
            if message.role == .user {
                turns.append(DesignTurn(id: message.id, prompt: message))
            } else if turns.isEmpty {
                turns.append(DesignTurn(id: message.id, work: [message]))
            } else {
                turns[turns.count - 1].work.append(message)
            }
        }

        var unplaced: [DesignRevision] = []
        for revision in revisions.sorted(by: { $0.number < $1.number }) {
            if let promptID = revision.promptID,
               let index = turns.firstIndex(where: { $0.prompt?.id == promptID }) {
                // Later versions of the same turn are the same files handed over again,
                // so the newest one stands for the turn.
                turns[index].revision = revision
            } else {
                unplaced.append(revision)
            }
        }

        var loose: [DesignTurn] = []
        for revision in unplaced {
            if let index = turns.lastIndex(where: { $0.date <= revision.createdAt }),
               turns[index].revision == nil {
                turns[index].revision = revision
            } else {
                loose.append(DesignTurn(id: revision.id, revision: revision))
            }
        }
        guard !loose.isEmpty else { return turns }
        // A stable merge by date keeps the conversation's own order intact.
        var merged: [DesignTurn] = []
        var pending = loose[...]
        for turn in turns {
            while let next = pending.first, next.date < turn.date {
                merged.append(next)
                pending = pending.dropFirst()
            }
            merged.append(turn)
        }
        return merged + pending
    }
}
