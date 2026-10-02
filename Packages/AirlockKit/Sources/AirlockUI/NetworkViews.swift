import AirlockControl
import AirlockCore
import AirlockEngine
import SwiftUI

/// Under the task header while the agent has been refused hosts nobody has decided on.
struct BlockedBanner: View {
    @Environment(AppModel.self) private var model
    let task: AgentTask

    var body: some View {
        if let summary = task.blockedSummary {
            HStack(spacing: 8) {
                Image(systemName: "network.slash")
                    .foregroundStyle(.orange)
                Text(summary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button("Review…") { model.blockedReview = TaskRef(task.id) }
                    .controlSize(.small)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.orange.opacity(0.12), in: .rect(cornerRadius: 8))
        }
    }
}

/// The familiar permission prompt: which blocked hosts to let through.
struct BlockedHostsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID
    @State private var unchecked: Set<String> = []
    @State private var forProject = false

    var body: some View {
        let task = model.tasks[taskID]
        let hosts = task?.blockedHosts ?? []
        let project = task.flatMap(model.project(for:))
        VStack(spacing: 14) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("“\(task?.title ?? "This task")” wants to connect to")
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(hosts.enumerated()), id: \.element.id) { index, host in
                    if index > 0 { Divider() }
                    Toggle(isOn: Binding(
                        get: { !unchecked.contains(host.name) },
                        set: { on in if on { unchecked.remove(host.name) } else { unchecked.insert(host.name) } }
                    )) {
                        HStack {
                            Text(host.name).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(host.attempts == 1 ? "once" : "\(host.attempts)×")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
            .background(.background, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            if let project {
                Toggle("Allow for all \(project.name) tasks", isOn: $forProject)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    let names = hosts.map(\.name)
                    Task { await model.declineBlocked(taskID, names) }
                    dismiss()
                } label: {
                    Text("Don’t Allow").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    let allowed = hosts.map(\.name).filter { !unchecked.contains($0) }
                    let declined = hosts.map(\.name).filter { unchecked.contains($0) }
                    let forProject = forProject
                    Task {
                        await model.allowBlocked(taskID, allowed, forProject: forProject)
                        await model.declineBlocked(taskID, declined)
                    }
                    dismiss()
                } label: {
                    Text("Allow").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(hosts.allSatisfy { unchecked.contains($0.name) })
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 340)
        .onChange(of: hosts.isEmpty) { if hosts.isEmpty { dismiss() } }
    }
}

/// The hosts a task (live) or a project's new tasks may reach, as a plain +/− list.
struct NetworkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: NetworkEditTarget
    @State private var selection: Set<String> = []
    @State private var adding = false
    @State private var newHost = ""
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if isOpenNetwork {
                Text("This task has an open network, so every host is reachable.")
                    .foregroundStyle(.secondary)
            } else {
                list
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 420)
    }

    var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(hosts, id: \.self) { host in
                    HStack(spacing: 6) {
                        Text(host).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let source = source(of: host) {
                            Text(source).font(.caption).foregroundStyle(.tertiary)
                        }
                        if unresolved.contains(host) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .help("No addresses found for this host. Check the spelling.")
                        }
                    }
                    .tag(host)
                }
                if adding {
                    TextField("pypi.org", text: $newHost)
                        .textFieldStyle(.plain)
                        .font(.body.monospaced())
                        .focused($fieldFocused)
                        .onSubmit(commit)
                        .onExitCommand { adding = false; newHost = ""; error = nil }
                        .onChange(of: newHost) { error = nil }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(minHeight: 150)
            .onDeleteCommand(perform: removeSelected)
            .overlay {
                if hosts.isEmpty && !adding {
                    Text("No extra hosts").foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 0) {
                Button { startAdding() } label: { Image(systemName: "plus").frame(width: 22, height: 18) }
                    .help("Add a host")
                Divider().frame(height: 14)
                Button { removeSelected() } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                    .disabled(selection.isEmpty)
                    .help("Remove the selected hosts")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 3)
            .padding(.horizontal, 2)
        }
    }

    // MARK: Model

    var task: AgentTask? { if case .task(let id) = target { model.tasks[id] } else { nil } }
    var project: Project? {
        switch target {
        case .task: task.flatMap(model.project(for:))
        case .project(let id): model.project(id)
        }
    }

    var isOpenNetwork: Bool { task.map { !$0.network.isRestricted } ?? false }

    var hosts: [String] {
        switch target {
        case .task:
            if case .restricted(let extra)? = task?.network { return extra }
            return []
        case .project:
            return project?.allowedHosts ?? []
        }
    }

    var unresolved: Set<String> { task.flatMap { model.unresolvedHosts[$0.id] } ?? [] }

    /// A task's host that came with its project's defaults.
    func source(of host: String) -> String? {
        guard task != nil, let project, project.allowedHosts.contains(host) else { return nil }
        return project.name
    }

    var title: String {
        switch target {
        case .task: "Allowed hosts"
        case .project: "Allowed hosts for new \(project?.name ?? "project") tasks"
        }
    }

    var footnote: String {
        switch target {
        case .task:
            let builtIn = task?.githubAccess == true ? "The agent’s API, package registries and GitHub" : "The agent’s API and package registries"
            return "\(builtIn) are always allowed. A host covers its subdomains. Changes apply right away, to its services too."
        case .project:
            return "New restricted tasks in this project start with these hosts. Running tasks aren’t changed."
        }
    }

    func startAdding() {
        adding = true
        error = nil
        DispatchQueue.main.async { fieldFocused = true }
    }

    func commit() {
        let host = newHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { adding = false; return }
        Task {
            if let message = await model.addHost(host, to: target) {
                error = message
            } else {
                newHost = ""
                fieldFocused = true
            }
        }
    }

    func removeSelected() {
        let names = Array(selection)
        guard !names.isEmpty else { return }
        selection = []
        Task { await model.removeHosts(names, from: target) }
    }
}

/// A chat's request that widens a sandbox. Only the user can allow it, here: a chat can be
/// talked into asking by what the agent wrote.
struct ApprovalSheet: View {
    @Environment(AppModel.self) private var model
    let request: ApprovalRequest

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(request.title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let review = request.handoff {
                HandoffReviewContent(review: review)
            } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(request.items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider() }
                    Text(item)
                        .font(.body.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
            }
            .background(.background, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            }
            Text(request.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    model.answerApproval(request.id, allowed: false)
                } label: {
                    Text("Don’t Allow").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    model.answerApproval(request.id, allowed: true)
                } label: {
                    Text(request.confirmTitle).frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: request.handoff == nil ? 340 : 420)
    }
}
