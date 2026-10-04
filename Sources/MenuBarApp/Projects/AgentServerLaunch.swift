import Foundation

// Translate the resolved CLI settings into each agent's server protocol, preserving
// the same model, workspace roots, access limits, and disabled integrations.
struct AgentServerLaunch: Sendable {
    let agent: AgentKind
    let arguments: [String]
    let sessionParameters: Data
    let resume: Bool
    let fullAccess: Bool
    let directories: [String]

    init(agent: AgentKind, arguments: [String], directory: String, resumeID: String?) throws {
        self.agent = agent
        resume = resumeID != nil
        fullAccess = arguments.contains("--allow-all")
            || arguments.contains("--dangerously-bypass-approvals-and-sandbox")
        var parameters: [String: Any] = agent == .codex
            ? ["cwd": directory] : ["workingDirectory": directory, "streaming": false,
                                      "requestPermission": true, "requestUserInput": true]
        var serverArguments = agent == .codex ? ["app-server"]
            : ["--headless", "--stdio", "--no-auto-update", "--log-level", "none"]
        var additionalDirectories: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch argument {
            case "-c":
                if let value { serverArguments += [argument, value]; index += 1 }
            case "--model":
                if let value { parameters["model"] = value; index += 1 }
            case "--effort", "--reasoning-effort":
                if let value { parameters["reasoningEffort"] = value; index += 1 }
            case "--add-dir":
                if let value { additionalDirectories.append(value); index += 1 }
            case "--session-id":
                if let value { parameters["sessionId"] = value; index += 1 }
            case "--disable-mcp-server":
                if let value { serverArguments += [argument, value]; index += 1 }
            case "--disable-builtin-mcps", "--allow-all", "--allow-all-tools":
                serverArguments.append(argument)
            case "--approve-for-me":
                serverArguments += ["-c", "approval_policy=\"on-failure\"",
                                    "-c", "approvals_reviewer=\"auto_review\""]
            case "-p":
                // This includes any design instructions prepended by the turn planner.
                if let value { parameters["initialPrompt"] = value; index += 1 }
            default:
                break
            }
            index += 1
        }
        directories = additionalDirectories
        if agent == .codex {
            if fullAccess {
                parameters["sandbox"] = "danger-full-access"
                parameters["approvalPolicy"] = "never"
            } else if !serverArguments.contains("approvals_reviewer=\"auto_review\"") {
                parameters["approvalPolicy"] = "never"
            }
            parameters["runtimeWorkspaceRoots"] = [directory] + additionalDirectories
            if let resumeID { parameters["threadId"] = resumeID }
            else { parameters["experimentalRawEvents"] = false }
        } else {
            parameters["additionalDirectories"] = additionalDirectories
            if let resumeID { parameters["sessionId"] = resumeID }
        }
        self.arguments = serverArguments
        sessionParameters = try JSONSerialization.data(withJSONObject: parameters)
    }
}
