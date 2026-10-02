import Foundation

/// The status bucket a task is listed under.
public enum StatusGroup: Int, CaseIterable, Comparable, Sendable {
    /// Waiting on a person: asked something, or failed.
    case needsYou
    /// Starting up or working.
    case running
    /// Finished a turn, stopped, exited or marked done.
    case recent

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .running: "Running"
        case .recent: "Recent"
        }
    }
}

/// What a task is doing, in the words the UI and the plugin use.
public enum TaskStatus: String, Sendable {
    case starting, working, needsInput = "needs_input", ready, failed, exited, stopped, done

    public var title: String {
        switch self {
        case .starting: "Starting"
        case .working: "Running"
        case .needsInput: "Needs input"
        case .ready: "Ready"
        case .failed: "Failed"
        case .exited: "Exited"
        case .stopped: "Stopped"
        case .done: "Done"
        }
    }
}

extension AgentTask {
    public var status: TaskStatus {
        if isDone { return .done }
        switch lifecycle {
        case .failed: return .failed
        case .stopped: return .stopped
        case .provisioning, .buildingImage, .starting: return .starting
        case .running:
            switch activity {
            case .needsInput: return .needsInput
            // A turn that ended with hosts it couldn't reach: likely why it stopped short.
            case .idle where !blockedHosts.isEmpty: return .needsInput
            case .idle: return .ready
            case .error: return .failed
            case .exited: return .exited
            case .working, .unknown: return .working
            }
        }
    }

    /// One line explaining the status: the failure, the question, the current step.
    public var statusDetail: String? {
        switch lifecycle {
        case .failed(let message): return message
        case .provisioning, .buildingImage, .starting: return lifecycle.displayName
        case .stopped, .running: break
        }
        switch activity {
        case .needsInput(let reason): return reason
        case .idle where !blockedHosts.isEmpty: return blockedSummary
        case .idle(let message): return message
        case .error(let reason): return reason
        case .working(let tool): return tool
        case .exited, .unknown: return nil
        }
    }

    /// "Blocked pypi.org", "Blocked pypi.org and 2 others"; nil when nothing is blocked.
    public var blockedSummary: String? {
        guard let first = blockedHosts.first else { return nil }
        let others = blockedHosts.count - 1
        return others == 0 ? "Blocked \(first.name)" : "Blocked \(first.name) and \(others) other\(others == 1 ? "" : "s")"
    }

    public var statusGroup: StatusGroup {
        switch status {
        case .needsInput, .failed: .needsYou
        case .starting, .working: .running
        case .ready, .exited, .stopped, .done: .recent
        }
    }

    public var recency: Date { lastActivityAt ?? updatedAt }
}

/// What the sidebar has selected; decides which tasks the list shows.
public enum SidebarScope: Hashable, Sendable {
    case active
    case needsYou
    case all
    case project(UUID)
    case tag(String)

    /// Whether rows should name the task's project (scopes that span projects).
    public var spansProjects: Bool {
        if case .project = self { return false }
        return true
    }
}

public enum TaskGrouping {
    public static func tasks(_ tasks: [AgentTask], in scope: SidebarScope) -> [AgentTask] {
        tasks.filter { task in
            switch scope {
            case .active: task.statusGroup != .recent
            case .needsYou: task.statusGroup == .needsYou
            case .all: true
            case .project(let id): task.projectID == id
            case .tag(let tag): task.tags.contains(tag)
            }
        }
    }

    /// Splits tasks into status buckets (empty ones left out), newest first in each.
    public static func group(_ tasks: [AgentTask]) -> [(group: StatusGroup, tasks: [AgentTask])] {
        Dictionary(grouping: tasks, by: \.statusGroup)
            .map { group, tasks in (group: group, tasks: tasks.sorted { $0.recency > $1.recency }) }
            .sorted { $0.group < $1.group }
    }

    /// Case-insensitive match on title, project name and tags.
    public static func filter(_ tasks: [AgentTask], query: String, projectName: (AgentTask) -> String?) -> [AgentTask] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return tasks }
        return tasks.filter { task in
            task.title.lowercased().contains(needle)
                || (projectName(task)?.lowercased().contains(needle) ?? false)
                || task.tags.contains { $0.contains(needle) }
        }
    }

    /// Projects with recent activity first; projects without tasks last, by name.
    public static func sortedProjects(_ projects: [Project], tasks: [AgentTask]) -> [Project] {
        let latest = Dictionary(grouping: tasks, by: \.projectID).compactMapValues { $0.map(\.recency).max() }
        return projects.sorted { a, b in
            let la = latest[a.id] ?? .distantPast, lb = latest[b.id] ?? .distantPast
            if la != lb { return la > lb }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Every tag in use, alphabetically.
    public static func tags(_ tasks: [AgentTask]) -> [String] {
        Array(Set(tasks.flatMap(\.tags))).sorted()
    }
}
