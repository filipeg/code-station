import Foundation
import Testing
@testable import MenuBarApp

struct DesignVersionsTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func message(_ role: MessageRole, _ text: String, at minute: Double) -> ChatMessage {
        ChatMessage(role: role, text: text, date: start.addingTimeInterval(minute * 60))
    }

    private func revision(_ number: Int, at minute: Double, prompt: UUID? = nil) -> DesignRevision {
        DesignRevision(id: UUID(), number: number,
                       createdAt: start.addingTimeInterval(minute * 60),
                       sourceRevisions: [:], screens: [], promptID: prompt)
    }

    @Test func eachPromptStartsATurnAndKeepsItsWork() {
        let first = message(.user, "A login screen", at: 0)
        let reply = message(.assistant, "Built it.", at: 1)
        let second = message(.user, "What font?", at: 2)
        let answer = message(.assistant, "SF Pro.", at: 3)

        let turns = DesignTurns.build(messages: [first, reply, second, answer], revisions: [])

        #expect(turns.map(\.id) == [first.id, second.id])
        #expect(turns[0].work == [reply])
        #expect(turns[1].work == [answer])
        #expect(turns.allSatisfy { $0.revision == nil })
    }

    @Test func aVersionSitsWithThePromptThatMadeIt() {
        let first = message(.user, "A login screen", at: 0)
        let second = message(.user, "Make it green", at: 5)
        let v1 = revision(1, at: 4, prompt: first.id)
        let v2 = revision(2, at: 9, prompt: second.id)
        // Handing the same turn over again saves another version for it.
        let v3 = revision(3, at: 10, prompt: second.id)

        let turns = DesignTurns.build(messages: [first, second], revisions: [v3, v1, v2])

        #expect(turns.map(\.revision?.id) == [v1.id, v3.id])
    }

    @Test func versionsSavedByHandJoinTheTurnRunningAtTheTime() {
        let first = message(.user, "A login screen", at: 0)
        let second = message(.user, "Make it green", at: 5)
        let saved = revision(1, at: 3)

        let turns = DesignTurns.build(messages: [first, second], revisions: [saved])

        #expect(turns.map(\.revision?.id) == [saved.id, nil])
    }

    @Test func aVersionWithNoFreeTurnStillGetsACard() {
        let first = message(.user, "A login screen", at: 5)
        let early = revision(1, at: 1)
        let made = revision(2, at: 6, prompt: first.id)
        let late = revision(3, at: 7)

        let turns = DesignTurns.build(messages: [first], revisions: [early, made, late])

        #expect(turns.map(\.id) == [early.id, first.id, late.id])
        #expect(turns.map(\.revision?.id) == [early.id, made.id, late.id])
        #expect(turns[0].title == "Design v1")
    }

    @Test func titleReadsThePromptOnOneLine() {
        let prompt = message(.user, "A login screen\n\nwith   passkeys", at: 0)
        let turns = DesignTurns.build(messages: [prompt], revisions: [])
        #expect(turns.first?.title == "A login screen with passkeys")
    }
}
