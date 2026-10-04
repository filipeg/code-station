import Foundation
import Observation

// The work Code Station does on a server that an agent owns: signing in, turning it on
// or off, asking how it is doing. Each server has at most one piece of work at a time,
// and a sign-in waits on the browser, so each one can be cancelled.
@MainActor
@Observable
final class AgentServerWork {
    struct Failure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    private(set) var work: [String: AgentConfiguredServer.Work] = [:]
    var errors: [String: String] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    func perform<Value: Sendable>(
        _ kind: AgentConfiguredServer.Work,
        on name: String,
        _ operation: @escaping @Sendable () async throws -> Value,
        then finish: @escaping @MainActor (Value) -> Void = { _ in },
        otherwise recover: @escaping @MainActor () -> Void = {}
    ) {
        tasks[name]?.cancel()
        work[name] = kind
        errors[name] = nil
        tasks[name] = Task { [weak self] in
            let result: Result<Value, Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            work[name] = nil
            tasks[name] = nil
            switch result {
            case .success(let value): finish(value)
            case .failure(let error):
                errors[name] = error.localizedDescription
                recover()
            }
        }
    }

    // Stopping the task stops the CLI too: CommandRunner ends the process group when
    // the task that awaits it is cancelled.
    func cancel(_ name: String) {
        tasks[name]?.cancel()
        tasks[name] = nil
        work[name] = nil
    }

    // What the command printed, or a failure carrying what it said on the way out.
    nonisolated static func output(_ command: String, _ arguments: [String],
                                   timeout: Duration) async throws -> String {
        guard let executable = ProcessManager.resolve(command) else {
            throw Failure(message: "\(command) not found on PATH.")
        }
        let result = try await CommandRunner.run(executable: executable,
                                                 arguments: arguments,
                                                 environment: CLIRegistrar.environment,
                                                 timeout: timeout)
        guard result.succeeded else {
            let said = [result.errorOutput, result.output]
                .map(\.trimmed).filter { !$0.isEmpty }.joined(separator: "\n")
            throw Failure(message: said.isEmpty ? "Command failed (exit \(result.status))." : said)
        }
        return result.output
    }
}
