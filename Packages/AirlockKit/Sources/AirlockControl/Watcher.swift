import AirlockCore
import AirlockEngine
import Foundation

/// `AIrlock --watch <task> [--after <event>]`: prints one line per progress step and
/// exits when the agent's turn ends. Meant for Claude Code's Monitor tool, where each
/// line becomes a notification in the chat that handed the task off.
public struct Watcher: Sendable {
    let client: ControlClient
    let taskID: String
    let afterEventID: Int?
    let interval: Duration
    let print: @Sendable (String) -> Void

    public init(client: ControlClient, taskID: String, afterEventID: Int?, interval: Duration = .seconds(1),
                print: @escaping @Sendable (String) -> Void = { Swift.print($0); fflush(stdout) }) {
        self.client = client
        self.taskID = taskID
        self.afterEventID = afterEventID
        self.interval = interval
        self.print = print
    }

    /// Parses the arguments after `--watch`, runs, then exits.
    public static func runAsProcess(socketPath: String, arguments: [String]) -> Never {
        guard let index = arguments.firstIndex(of: "--watch"), arguments.indices.contains(index + 1) else {
            FileHandle.standardError.write(Data("usage: AIrlock --watch <task-id> [--after <event-id>]\n".utf8))
            exit(2)
        }
        let after = arguments.firstIndex(of: "--after").flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil }
        let watcher = Watcher(client: ControlClient(socketPath: socketPath), taskID: arguments[index + 1], afterEventID: after)
        Task.detached {
            let code = await watcher.run()
            exit(code)
        }
        dispatchMain()
    }

    /// Polls until the turn ends. Returns the process exit code.
    public func run() async -> Int32 {
        let label: String
        do {
            let snapshot: TaskSnapshot = try await client.call(.getTask, TaskParams(taskID: taskID))
            label = snapshot.shortID
        } catch {
            print("\(taskID) error: \(error)")
            return 1
        }
        var after = afterEventID
        var lastLine: String?
        var knownPorts: Set<String>?
        var reportedBlocked: Set<String> = []
        var lastPhase: String?
        var lastSetup: String?
        var failures = 0
        while !Task.isCancelled {
            do {
                let progress: TaskProgress = try await client.call(.watchTask, WatchParams(taskID: label, afterEventID: after))
                failures = 0
                after = progress.lastEventID
                let ports = Set(progress.ports)
                // Report forwards opened or closed while watching (not the ones already there).
                if let known = knownPorts { Self.portLines(label, known: known, current: ports).forEach(print) }
                knownPorts = ports
                // An inspection's steps, as they happen (AIrlock's own words).
                if let phase = progress.inspectionPhase, phase != lastPhase {
                    print("\(label) inspection: \(phase)\(phase == "Report ready" || phase == "Claude is investigating" ? ". Read the report with get_task." : "")")
                    lastPhase = phase
                }
                // A sealed task's setup, before its agent starts.
                if let setup = progress.setupPhase, setup != lastSetup {
                    if lastSetup != nil || setup != "Setup done" { print("\(label) setup: \(setup)") }
                    lastSetup = setup
                }
                // Each refused host once, as soon as it's seen, so the chat can ask the user.
                for host in progress.blocked where progress.inspectionPhase == nil && !reportedBlocked.contains(host) && UntrustedText.isHostname(host) {
                    print("\(label) blocked: \(host). Ask the user whether to allow it, then call allow_domains.")
                    reportedBlocked.insert(host)
                }
                for line in Self.lines(label, progress) where line != lastLine {
                    print(line)
                    lastLine = line
                }
                if progress.ended { return 0 }
            } catch {
                // The app restarting or a removed task: give up after ~10 seconds of errors.
                failures += 1
                if failures >= 10 {
                    print("\(label) error: \(error)")
                    return 1
                }
            }
            try? await Task.sleep(for: interval)
        }
        return 0
    }

    static func portLines(_ label: String, known: Set<String>, current: Set<String>) -> [String] {
        current.subtracting(known).sorted().map { "\(label) port: \($0)" }
            + known.subtracting(current).sorted().map { "\(label) port closed: \($0)" }
    }

    /// Lines for one poll: new milestones, then how the turn ended, if it did. Milestones and
    /// details are the agent's words: each is one clean line, so it can't fake a line of its own.
    static func lines(_ label: String, _ p: TaskProgress) -> [String] {
        var out = p.milestones.map { "\(label) progress (agent): \(UntrustedText.oneLine($0))" }
        let detail = p.detail.map { ": \(UntrustedText.oneLine($0))" } ?? ""
        switch p.status {
        case "needs_input" where p.ended:
            out.append("\(label) needs input\(detail). Read it with get_task.")
        case "ready" where p.ended:
            out.append("\(label) ready: finished its turn (event \(p.lastEventID)). Read its reply with get_task.")
        case "failed":
            out.append("\(label) failed\(detail)")
        case "exited":
            out.append("\(label) exited: the agent process ended. resume_task starts it again.")
        case "stopped":
            out.append("\(label) stopped")
        case "done":
            out.append("\(label) done")
        default:
            break
        }
        return out
    }
}
