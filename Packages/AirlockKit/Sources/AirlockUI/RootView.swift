import AirlockCore
import AirlockEngine
import AirlockRuntime
import AirlockWorkspace
import AppKit
import SwiftUI

public struct RootView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            TaskListView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            if let task = model.selectedTask {
                TaskDetailView(task: task, tab: model.demoDetailTab)
                    .id("\(task.id)-\(model.demoDetailTab)")
            } else {
                EmptyDetailView()
            }
        }
        .searchable(text: $model.filterText, placement: .toolbar, prompt: "Filter")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isDemo, !model.hidesDemoBadge {
                    Text("Demo")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.purple.opacity(0.15), in: .capsule)
                        .foregroundStyle(.purple)
                        .help("Sample data on a pretend runtime. Nothing here runs.")
                }
                RuntimeWarning()
                Button {
                    model.isPresentingNewTask = true
                } label: {
                    Label("New task", systemImage: "plus")
                }
                .keyboardShortcut("n")
                .help("New task")
            }
        }
        .sheet(isPresented: $model.isPresentingNewTask) {
            NewTaskSheet()
        }
        .sheet(isPresented: $model.isPresentingNewProject) {
            NewProjectSheet()
        }
        .sheet(item: $model.networkEditor) { target in
            NetworkSheet(target: target)
        }
        .sheet(item: $model.blockedReview) { ref in
            BlockedHostsSheet(taskID: ref.id)
        }
        .sheet(item: $model.handoffSheet) { ref in
            HandoffSheet(taskID: ref.id)
        }
        // Answered by its buttons; the next waiting request (if any) takes its place.
        .sheet(item: Binding(get: { model.approvals.first }, set: { _ in })) { request in
            ApprovalSheet(request: request)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct EmptyDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label(model.tasks.isEmpty ? "No tasks yet" : "No task selected", systemImage: "shippingbox")
        } description: {
            Text("Ask Claude to hand off work to AIrlock, or start one here. Each task runs an agent in its own container.")
        } actions: {
            Button("New task") { model.isPresentingNewTask = true }
        }
    }
}

/// Shown only when no container runtime is reachable.
struct RuntimeWarning: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let statuses = model.runtimeStatus
        if !statuses.isEmpty, !statuses.values.contains(where: \.isAvailable) {
            Button { openSettings() } label: {
                Label("No container runtime", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .help(statuses[.docker].flatMap { if case .unavailable(let reason) = $0 { reason } else { nil } }
                  ?? "No container runtime is available. Open Settings › Runtimes.")
        }
    }
}

struct NewProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var repoPath = ""
    @State private var repoError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New project")
                .font(.title2.weight(.semibold))
                .padding([.horizontal, .top], 20)
            Form {
                TextField("Name", text: $name, prompt: Text("Webapp redesign"))
                LabeledContent("Repository") {
                    HStack {
                        Text(repoPath.isEmpty ? "Choose a repository or folder" : repoPath)
                            .foregroundStyle(repoPath.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button("Choose…", action: chooseRepo)
                    }
                }
                if let repoError { Text(repoError).foregroundStyle(.red).font(.callout) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let (name, repoPath) = (name, repoPath)
                    Task { await model.createProject(name: name, repoPath: repoPath) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || repoPath.isEmpty || repoError != nil)
            }
            .padding(20)
        }
        .frame(width: 480)
        .onAppear {
            if case .project(let id) = model.scope, let project = model.project(id) { repoPath = project.repoPath }
        }
    }

    func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            // A folder outside any repository works too; tasks there get a temporary .git.
            repoPath = (try? await HostGit(url).run("rev-parse", "--show-toplevel")) ?? Workspaces.realPath(url.path)
            repoError = nil
        }
    }
}
