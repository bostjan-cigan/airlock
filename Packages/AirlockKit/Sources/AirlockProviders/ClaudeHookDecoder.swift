import AirlockCore
import Foundation

/// Decodes lines written by `airlock-hook` for Claude Code:
/// `{"ts": "...", "event": "PreToolUse", "payload": {...hook input...}}`.
public struct ClaudeHookDecoder: AgentEventDecoder {
    /// Maps container paths (e.g. `/home/node/.claude/...`) to host paths.
    public var hostPath: @Sendable (String) -> String?

    public init(hostPath: @escaping @Sendable (String) -> String? = { _ in nil }) {
        self.hostPath = hostPath
    }

    struct Line: Decodable {
        var ts: String
        var event: String
        var payload: Payload
    }

    struct Payload: Decodable {
        var tool_name: String?
        var tool_input: [String: JSONValue]?
        var prompt: String?
        var message: String?
        var transcript_path: String?
        var source: String?
        var reason: String?
        var notification_type: String?
        var tool_response: JSONValue?
        // StopFailure
        var error: String?
        var error_details: String?
        var last_assistant_message: String?
    }

    public func decode(line: String, index: Int) -> AgentEvent? {
        guard let parsed = try? JSONDecoder().decode(Line.self, from: Data(line.utf8)) else { return nil }
        let p = parsed.payload
        let ts = Self.dateFormatter.date(from: parsed.ts) ?? .now
        let transcript = p.transcript_path.flatMap(hostPath)

        // Every string here comes from the agent's side; the app and the chat get one clean line.
        func event(_ kind: AgentEvent.Kind, _ summary: String, tool: String? = nil, milestone: String? = nil) -> AgentEvent {
            AgentEvent(id: index, timestamp: ts, kind: kind, toolName: tool.map { UntrustedText.oneLine($0, limit: 60) },
                       summary: UntrustedText.oneLine(summary, limit: 240), transcriptPath: transcript,
                       milestone: milestone.map { UntrustedText.oneLine($0, limit: 240) })
        }

        switch parsed.event {
        case "SessionStart": return event(.sessionStart, p.source == "resume" ? "Session resumed" : "Session started")
        case "UserPromptSubmit": return event(.prompt, Self.oneLine(p.prompt ?? ""))
        case "PreToolUse": return event(.toolStart, Self.describe(tool: p.tool_name, input: p.tool_input), tool: p.tool_name)
        case "PostToolUse":
            return event(.toolEnd, Self.describe(tool: p.tool_name, input: p.tool_input), tool: p.tool_name,
                         milestone: Self.milestone(tool: p.tool_name, input: p.tool_input, response: p.tool_response))
        case "Notification":
            // Sent a minute after every finished turn; the agent is just sitting at its prompt.
            if p.notification_type == "idle_prompt" { return event(.other, "Waiting at its prompt") }
            return event(.notification, p.message.map { Self.oneLine($0) } ?? "Waiting for input")
        case "Stop": return event(.stop, "Finished its turn")
        case "StopFailure": return event(.stopFailure, Self.failureReason(error: p.error, details: p.error_details ?? p.last_assistant_message))
        case "SubagentStop": return event(.subagentStop, "Subagent finished")
        case "PreCompact": return event(.compact, "Compacting context")
        case "SessionEnd": return event(.sessionEnd, "Session ended")
        default: return event(.other, parsed.event)
        }
    }

    static func describe(tool: String?, input: [String: JSONValue]?) -> String {
        let tool = tool ?? "Tool"
        let input = input ?? [:]
        func str(_ key: String) -> String? { input[key]?.stringValue }
        func file(_ key: String) -> String? {
            str(key).map { $0.hasPrefix("/workspace/") ? String($0.dropFirst("/workspace/".count)) : $0 }
        }
        let detail: String? = switch tool {
        case "Bash": str("command").map(oneLine)
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit": file("file_path") ?? file("notebook_path")
        case "Grep", "Glob": str("pattern")
        case "WebFetch": str("url")
        case "WebSearch": str("query")
        case "Task", "Agent": str("description")
        case "TodoWrite": "Update todos"
        default: nil
        }
        return detail.map { "\(tool) \($0)" } ?? tool
    }

    /// Readable reason for an API error that ended the agent's turn.
    static func failureReason(error: String?, details: String?) -> String {
        let reason = switch error {
        case "billing_error": "Out of API credits"
        case "authentication_failed": "Authentication failed"
        case "oauth_org_not_allowed": "This account's organization doesn't allow Claude Code"
        case "account_on_hold": "Account on hold"
        case "verification_required": "Account needs verification"
        case "rate_limit": "Rate limited"
        case "overloaded": "API overloaded"
        case "model_not_found": "Model not available"
        case "max_output_tokens": "Hit the output token limit"
        case "server_error": "API server error"
        case "invalid_request": "Invalid API request"
        default: "API error"
        }
        guard let details = details.map(oneLine), !details.isEmpty, details != reason else { return reason }
        return "\(reason): \(details)"
    }

    /// A step worth relaying: the agent's todo list moving on, or a commit.
    static func milestone(tool: String?, input: [String: JSONValue]?, response: JSONValue?) -> String? {
        let input = input ?? [:]
        switch tool {
        case "TodoWrite":
            guard let todos = input["todos"]?.arrayValue, !todos.isEmpty else { return nil }
            let done = todos.filter { $0["status"]?.stringValue == "completed" }.count
            if done == todos.count { return "All \(todos.count) steps done" }
            guard let current = todos.first(where: { $0["status"]?.stringValue == "in_progress" }) else { return nil }
            let text = current["activeForm"]?.stringValue ?? current["content"]?.stringValue ?? "Working"
            return "\(oneLine(text)) (\(done)/\(todos.count) done)"
        case "TaskUpdate":
            let text = input["activeForm"]?.stringValue ?? input["subject"]?.stringValue
            switch input["status"]?.stringValue {
            case "in_progress": return text.map(oneLine)
            case "completed": return input["subject"]?.stringValue.map { "Done: \(oneLine($0))" }
            default: return nil
            }
        case "Bash":
            guard let command = input["command"]?.stringValue else { return nil }
            let stdout = response?["stdout"]?.stringValue ?? response?.stringValue ?? ""
            let stderr = response?["stderr"]?.stringValue ?? ""
            if response?["interrupted"] == .bool(true) { return nil }
            // One command can run the tests and commit; report both.
            let steps = [
                testRunner(command).map { testMilestone($0, output: stdout + "\n" + stderr) },
                command.contains("git commit") ? commitMilestone(stdout: stdout, stderr: stderr) : nil,
            ].compactMap { $0 }
            return steps.isEmpty ? nil : steps.joined(separator: " · ")
        default:
            return nil
        }
    }

    /// "Committed 1a2b3c4: Subject" from `git commit` (or a chained `git log --oneline`).
    static func commitMilestone(stdout: String, stderr: String) -> String? {
        let all = stdout + "\n" + stderr
        for bad in ["nothing to commit", "fatal:", "error:", "no changes added"] where all.contains(bad) { return nil }
        for line in stdout.split(separator: "\n") {
            // `git commit` prints "[branch 1a2b3c4] Subject".
            if line.hasPrefix("["), let close = line.firstIndex(of: "]"),
               let sha = line[line.index(after: line.startIndex)..<close].split(separator: " ").last,
               sha.count >= 7, sha.allSatisfy(\.isHexDigit) {
                return "Committed \(sha.prefix(7)): \(oneLine(line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)))"
            }
            // `git log --oneline -1` prints "1a2b3c4 Subject".
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].count >= 7, parts[0].count <= 40, parts[0].allSatisfy(\.isHexDigit) {
                return "Committed \(parts[0].prefix(7)): \(oneLine(String(parts[1])))"
            }
        }
        return "Committed changes"
    }

    /// The test command a shell line runs, if any.
    static func testRunner(_ command: String) -> String? {
        let runners = ["npm test", "npm run test", "pnpm test", "yarn test", "bun test", "node --test", "pytest", "go test",
                       "cargo test", "swift test", "mvn test", "gradle test", "./gradlew test", "rspec", "phpunit",
                       "vitest", "jest", "mix test", "dotnet test", "make test", "xcodebuild test"]
        return runners.first { command.contains($0) }
    }

    /// "Tests passed (npm test)" / "Tests failing (npm test)" when the output says, else "Ran tests (…)".
    static func testMilestone(_ runner: String, output: String) -> String {
        let text = output.lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { text.contains($0) } }
        if has(["# fail 0", " 0 failed", "0 failures", "test result: ok"]) { return "Tests passed (\(runner))" }
        if has(["# fail ", " failed", " failures", "failures:"]) { return "Tests failing (\(runner))" }
        if has([" passed", "# pass ", "tests passed"]) { return "Tests passed (\(runner))" }
        return "Ran tests (\(runner))"
    }

    /// Everything the hooks report is the agent's (or its tools') text: one clean line.
    static func oneLine(_ s: String) -> String {
        UntrustedText.oneLine(s, limit: 160)
    }

    nonisolated(unsafe) static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Full text of the last assistant message, cleaned and capped at `limit` characters.
    /// `data` may start mid-line (the end of a long transcript); that line is skipped.
    public static func lastAssistantText(transcript data: Data, limit: Int = 12_000) -> String? {
        struct Entry: Decodable {
            struct Message: Decodable {
                struct Block: Decodable { var type: String; var text: String? }
                var role: String?
                var content: [Block]?
            }
            var type: String?
            var message: Message?
        }
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let entry = try? JSONDecoder().decode(Entry.self, from: line), entry.type == "assistant",
                  let text = entry.message?.content?.compactMap({ $0.type == "text" ? $0.text : nil }).joined(separator: "\n"),
                  !text.isEmpty else { continue }
            return UntrustedText.block(text, limit: limit)
        }
        return nil
    }
}

/// Just enough JSON to pull strings out of arbitrary tool inputs.
public enum JSONValue: Decodable, Sendable, Hashable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}
