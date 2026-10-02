import AirlockCore
import SwiftUI

/// The middle column: the scope's tasks, newest first. Deliberately plain: title, project,
/// status and start time. Everything else is in the task's detail.
struct TaskListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let tasks = model.scopedTasks.sorted { $0.createdAt > $1.createdAt }
        List(selection: $model.selection) {
            ForEach(tasks) { task in
                TaskRow(task: task, showProject: model.scope.spansProjects)
                    .tag(task.id)
                    .contextMenu { TaskActions(task: task) }
            }
        }
        .overlay {
            if tasks.isEmpty { emptyState }
        }
        .navigationTitle(title)
        .navigationSubtitle(countLine(tasks))
    }

    var title: String {
        switch model.scope {
        case .active: "Active"
        case .needsYou: "Needs you"
        case .all: "All tasks"
        case .project(let id): model.project(id)?.name ?? "Project"
        case .tag(let tag): "#\(tag)"
        }
    }

    func countLine(_ tasks: [AgentTask]) -> String {
        let active = tasks.filter { $0.statusGroup != .recent }.count
        return active > 0 ? "\(active) in progress" : tasks.isEmpty ? "" : "\(tasks.count) task\(tasks.count == 1 ? "" : "s")"
    }

    @ViewBuilder
    var emptyState: some View {
        if !model.filterText.isEmpty {
            ContentUnavailableView.search(text: model.filterText)
        } else {
            switch model.scope {
            case .active, .needsYou:
                ContentUnavailableView("Nothing running", systemImage: "checkmark.circle",
                                       description: Text("Ask Claude to hand work off to AIrlock, or start a task here."))
            default:
                ContentUnavailableView("No tasks", systemImage: "tray",
                                       description: Text("Tasks you start here or from a Claude chat show up in this list."))
            }
        }
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let task: AgentTask
    var showProject = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusIndicator(task: task)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(task.title)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(StartTime.short(task.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    var subtitle: String {
        let project = showProject ? model.project(for: task)?.name : nil
        return [project, task.simpleStatus].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The one mark a list row carries: progress while it runs, a dot when it waits for
/// you, a warning when it failed, and nothing otherwise.
struct StatusIndicator: View {
    let task: AgentTask

    var body: some View {
        switch task.status {
        case .starting, .working:
            ProgressView().controlSize(.mini)
        case .needsInput:
            Circle().fill(.tint).frame(width: 8, height: 8)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .ready, .exited, .stopped, .done:
            Color.clear.frame(width: 8, height: 8)
        }
    }
}

extension AgentTask {
    /// The status in as few words as possible, for overviews.
    var simpleStatus: String {
        switch status {
        case .starting: "Starting"
        case .working: "Running"
        case .needsInput: "Waiting for you"
        case .failed: "Failed"
        case .ready: "Finished"
        case .exited, .stopped: "Stopped"
        case .done: "Done"
        }
    }
}

/// When a task started, as Mail shows dates: a time today, "Yesterday", then a date.
enum StartTime {
    static func short(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}
