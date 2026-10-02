import Foundation

/// A provider-neutral event from an agent's session, decoded from its hooks.
public struct AgentEvent: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case sessionStart, prompt, toolStart, toolEnd, notification, stop, stopFailure, subagentStop, compact, sessionEnd, other
    }

    /// Line number in the task's event log.
    public var id: Int
    public var timestamp: Date
    public var kind: Kind
    public var toolName: String?
    /// One-line description: the prompt, the file touched, the command run, the message shown.
    public var summary: String
    /// Agent transcript on the host, when the event carries one.
    public var transcriptPath: String?
    /// A step worth telling the user about ("Running tests (2/4 done)", "Committed 1a2b3c4: …").
    public var milestone: String?

    public init(id: Int, timestamp: Date, kind: Kind, toolName: String? = nil, summary: String,
                transcriptPath: String? = nil, milestone: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.toolName = toolName
        self.summary = summary
        self.transcriptPath = transcriptPath
        self.milestone = milestone
    }
}

/// Turns one line of a provider's event log into an event.
public protocol AgentEventDecoder: Sendable {
    func decode(line: String, index: Int) -> AgentEvent?
}

public enum ActivityReducer {
    /// The task's activity after `event`.
    public static func reduce(_ activity: Activity, _ event: AgentEvent) -> Activity {
        switch event.kind {
        // The prompt arrives on the command line, so a new session starts working right away.
        case .sessionStart, .prompt: .working(tool: nil)
        case .toolStart: .working(tool: event.summary)
        case .toolEnd: .working(tool: nil)
        case .notification: .needsInput(reason: event.summary)
        // The agent finished its turn; its result is ready.
        case .stop: .idle(lastMessage: nil)
        // An API error (credits, auth, rate limit) ended the turn.
        case .stopFailure: .error(reason: event.summary)
        case .sessionEnd: .exited
        case .subagentStop, .compact, .other: activity
        }
    }

    /// Whether moving into this event deserves a user notification.
    public static func shouldNotify(_ event: AgentEvent) -> Bool {
        [.stop, .stopFailure, .notification, .sessionEnd].contains(event.kind)
    }
}

extension Array where Element == AgentEvent {
    /// The most recent milestone since the agent last got a prompt.
    public var currentMilestone: String? {
        for event in reversed() {
            if let milestone = event.milestone { return milestone }
            if event.kind == .prompt { return nil }
        }
        return nil
    }
}
