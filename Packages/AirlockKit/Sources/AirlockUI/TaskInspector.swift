import AirlockCore
import AirlockEngine
import AirlockRuntime
import AppKit
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case containers, access, info

    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: "Containers"
        case .access: "Access"
        case .info: "Info"
        }
    }

    var symbol: String {
        switch self {
        case .containers: "square.stack.3d.up"
        case .access: "lock.shield"
        case .info: "info.circle"
        }
    }
}

/// The task's details, one topic per tab, the way Xcode's inspectors work.
struct TaskInspector: View {
    let task: AgentTask
    @Binding var tab: InspectorTab

    var body: some View {
        VStack(spacing: 0) {
            InspectorTabBar(selection: $tab, alert: task.services?.hasFailure == true ? .containers : nil)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .containers: ContainersTab(task: task)
                    case .access: AccessTab(task: task)
                    case .info: InfoTab(task: task)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Icon tabs; a small red dot on a tab that has something wrong in it.
struct InspectorTabBar: View {
    @Binding var selection: InspectorTab
    var alert: InspectorTab?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(InspectorTab.allCases) { tab in
                Button { selection = tab } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .foregroundStyle(selection == tab ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .overlay(alignment: .topTrailing) {
                            if alert == tab {
                                Circle().fill(.red).frame(width: 6, height: 6).offset(x: -18, y: 2)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
    }
}

// MARK: Building blocks

/// A titled, rounded group of rows, as in System Settings.
struct InspectorSection<Content: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let trailing { Text(trailing).font(.subheadline).foregroundStyle(.tertiary) }
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider() }
                        row
                    }
                }
            }
            .padding(.horizontal, 10)
            .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 8))
        }
        .padding(.top, 18)
    }
}

/// Label on the left, value on the right; the value turns orange for elevated access.
struct InspectorRow: View {
    let label: String
    var symbol: String?
    let value: String
    var elevated = false
    var mono = false
    var help: String?

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            }
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .foregroundStyle(elevated ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.system(size: 13))
        .padding(.vertical, 7)
        .help(help ?? "")
    }
}

// MARK: Containers

struct ContainersTab: View {
    @Environment(AppModel.self) private var model
    let task: AgentTask
    @State private var adding = false

    var body: some View {
        let services = task.services?.items ?? []
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection(title: "Containers", trailing: summary(services)) {
                ContainerRow(name: "Agent", color: agentColor, state: agentState,
                             ports: task.ports.filter { $0.service == nil }, task: task, usage: model.usage[task.id]?["agent"])
                ForEach(services) { service in
                    ServiceRow(task: task, service: service)
                }
                ForEach((task.services?.skipped ?? [:]).keys.sorted(), id: \.self) { name in
                    HStack(spacing: 8) {
                        Circle().strokeBorder(.tertiary).frame(width: 7, height: 7)
                        Text(name).foregroundStyle(.secondary)
                        Spacer()
                        Text("Skipped").foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 13))
                    .padding(.vertical, 7)
                    .help(task.services?.skipped[name] ?? "")
                }
            }
            if task.lifecycle == .running {
                Button { adding = true } label: { Label("Forward Port…", systemImage: "plus") }
                    .controlSize(.small)
                    .padding(.top, 10)
                    .popover(isPresented: $adding, arrowEdge: .bottom) { AddPortPopover(task: task) { adding = false } }
            }
            Text("Click a service for its image, logs and Restart. Ports open in your browser.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var agentColor: Color {
        switch task.lifecycle {
        case .running: task.activity == .exited ? .gray : .green
        case .provisioning, .buildingImage, .starting: .yellow
        case .stopped: .gray
        case .failed: .red
        }
    }

    var agentState: String? {
        switch task.lifecycle {
        case .running: task.activity == .exited ? "Exited" : nil
        case .provisioning, .buildingImage, .starting: "Starting"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }

    func summary(_ services: [ServiceInstance]) -> String {
        let running = (task.lifecycle == .running ? 1 : 0) + services.filter(\.state.isUp).count
        let starting = services.filter { [.pending, .pulling, .starting].contains($0.state) }.count
        let failed = services.filter { if case .failed = $0.state { true } else { false } }.count
        return [running > 0 ? "\(running) running" : nil, starting > 0 ? "\(starting) starting" : nil, failed > 0 ? "\(failed) failed" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// A container: status dot, name, and its forwarded ports (or its state when not up).
struct ContainerRow: View {
    let name: String
    let color: Color
    let state: String?
    let ports: [PortForward]
    let task: AgentTask
    var usage: ResourceUsage?

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            if let state {
                Text(state).foregroundStyle(.secondary)
            } else if let usage {
                Text(ResourcePlanner.gigabytes(usage.memoryMB))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .fixedSize()
                    .help("\(Int(usage.cpuPercent.rounded()))% CPU · \(ResourcePlanner.gigabytes(usage.memoryMB)) memory")
            }
            ForEach(ports) { PortPill(task: task, forward: $0) }
        }
        .font(.system(size: 13))
        .padding(.vertical, 7)
    }
}

/// A compose service row; clicking it shows its image, logs and Restart.
struct ServiceRow: View {
    @Environment(AppModel.self) private var model
    let task: AgentTask
    let service: ServiceInstance
    @State private var showing = false
    @State private var logs: String?
    @State private var hovering = false

    var body: some View {
        ContainerRow(name: service.name, color: service.state.color, state: service.state.isUp ? nil : service.state.shortTitle,
                     ports: task.ports.filter { $0.service == service.name }, task: task, usage: model.usage[task.id]?[service.name])
            .contentShape(.rect)
            .background(hovering ? Color.primary.opacity(0.05) : .clear, in: .rect(cornerRadius: 5))
            .onHover { hovering = $0 }
            .onTapGesture { showing = true }
            .help("\(service.name): \(service.state.title)")
            .popover(isPresented: $showing, arrowEdge: .leading) { details }
            .sheet(isPresented: Binding(get: { logs != nil }, set: { if !$0 { logs = nil } })) {
                LogsSheet(title: "\(service.name) logs", text: logs ?? "") { logs = nil }
            }
    }

    var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(service.state.color).frame(width: 8, height: 8)
                Text(service.name).font(.headline)
                Text(stateLine).foregroundStyle(.secondary)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Image", service.image)
                row("Address", service.address, mono: true)
                if !service.volumes.isEmpty { row("Data", service.volumes.joined(separator: ", ") + ", removed with the task") }
                if !service.dropped.isEmpty { row("Removed", service.dropped.joined(separator: "\n")) }
            }
            .font(.system(size: 13))
            HStack {
                Button("Logs") { Task { logs = (try? await model.engine.serviceLogs(task.id, service: service.name, tail: 500)) ?? "No logs." } }
                Button("Restart") { model.perform { try await $0.restartService(task.id, service: service.name) } }
                if let port = service.ports.first, !task.ports.contains(where: { $0.containerPort == port }) {
                    Button("Forward to localhost") { model.perform { try await $0.expose(task.id, port: port, service: service.name) } }
                }
            }
            .disabled(service.containerID == nil)
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }

    var stateLine: String {
        guard service.state.isUp, let started = service.startedAt else { return service.state.title }
        return "\(service.state.title) · up \(started.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)).replacingOccurrences(of: " ago", with: ""))"
    }

    func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// ":3000 ↗" — opens a web port in the browser, copies a service's address.
struct PortPill: View {
    @Environment(AppModel.self) private var model
    let task: AgentTask
    let forward: PortForward

    var opensInBrowser: Bool { forward.service == nil }

    var body: some View {
        Button {
            if opensInBrowser, let url = URL(string: forward.url) {
                NSWorkspace.shared.open(url)
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("localhost:\(forward.hostPort)", forType: .string)
            }
        } label: {
            HStack(spacing: 2) {
                Text(":\(String(forward.hostPort))").monospacedDigit()
                Image(systemName: opensInBrowser ? "arrow.up.right" : "doc.on.doc").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12))
            .foregroundStyle(.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(.quaternary))
            .contentShape(.capsule)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(opensInBrowser ? "Open \(forward.url)" : "Copy localhost:\(forward.hostPort)")
        .contextMenu {
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("localhost:\(forward.hostPort)", forType: .string)
            }
            Button("Stop Forwarding") { model.perform { await $0.unexpose(task.id, port: forward.containerPort) } }
        }
    }
}

// MARK: Access

struct AccessTab: View {
    @Environment(AppModel.self) private var model
    let task: AgentTask
    @State private var showingSetup = false

    var body: some View {
        if let inspection = task.inspection {
            inspectionAccess(inspection)
        } else {
            workAccess
        }
    }

    /// An inspection: no tokens (unless Claude investigates, through the proxy), a network
    /// that closes before the repository's code runs, and nothing to edit.
    func inspectionAccess(_ inspection: Inspection) -> some View {
        let downloading = inspection.phase == .preparing || inspection.phase == .downloading
        return VStack(alignment: .leading, spacing: 0) {
            InspectorSection(title: "Access") {
                InspectorRow(label: "Network", symbol: "lock.shield", value: downloading ? "Registries only" : "Closed",
                             help: downloading ? "Package registries while dependencies download, with install scripts off. It closes before any of the repository’s code runs."
                                               : "Nothing can leave: no hosts, no DNS.")
                InspectorRow(label: "GitHub", symbol: "arrow.triangle.branch", value: "None")
                InspectorRow(label: "Account", symbol: "key", value: inspection.investigate ? "Through a proxy" : "None",
                             help: inspection.investigate ? "Claude works inside; its token stays with AIrlock’s proxy, out of the code’s reach." : "No tokens in the VM.")
                InspectorRow(label: "Size", symbol: "cpu", value: sizeValue)
            }
            Text("Nothing comes back out: no branch, no files.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 14)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var workAccess: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection(title: "Access") {
                InspectorRow(label: "Network", symbol: task.network.isRestricted ? "lock.shield" : "globe",
                             value: task.isSealed ? "Sealed" : task.network.isRestricted ? "Restricted" : "Open", elevated: !task.network.isRestricted,
                             help: task.isSealed ? "Dependencies were installed before the network closed. Only Claude is reachable, through a proxy; hosts you allow open too."
                                                 : detail(.network))
                InspectorRow(label: "GitHub", symbol: "arrow.triangle.branch", value: github.value, elevated: github.elevated, help: detail(.github))
                InspectorRow(label: "Account", symbol: "key", value: account.value, elevated: account.elevated, help: detail(.credential))
                InspectorRow(label: "Size", symbol: "cpu", value: sizeValue,
                             help: "\(task.resources.summary)\(task.resourceReason.map { ", \($0)" } ?? ""). Choose it when starting a task, or per project.")
            }
            if let sealing = task.sealing {
                InspectorSection(title: "Setup") {
                    HStack(alignment: .firstTextBaseline) {
                        Text(sealing.report?.summary ?? sealing.phase.title)
                            .font(.system(size: 13))
                            .foregroundStyle((sealing.report?.findings ?? 0) > 0 ? .red : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if sealing.report != nil {
                            Button("Details…") { showingSetup = true }.controlSize(.small)
                        }
                    }
                    .padding(.vertical, 7)
                }
                .sheet(isPresented: $showingSetup) {
                    if let report = task.sealing?.report { SetupReportSheet(report: report) }
                }
            }
            if case .restricted(let hosts) = task.network {
                InspectorSection(title: "Allowed hosts", trailing: hosts.isEmpty ? nil : "\(hosts.count)") {
                    if hosts.isEmpty {
                        Text(task.isSealed ? "Only Claude, through the proxy" : "Only the agent’s API and package registries")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 7)
                    } else {
                        ForEach(hosts, id: \.self) { host in
                            Text(host)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 7)
                        }
                    }
                }
                Button("Edit Hosts…") { model.networkEditor = .task(task.id) }
                    .controlSize(.small)
                    .padding(.top, 10)
            }
            Text("Runs every tool without asking, inside the container only.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 14)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "1.2 of 8 GB · 4 CPU" while running, "4 CPU · 8 GB" otherwise.
    var sizeValue: String {
        guard let used = model.usage[task.id]?["agent"] else { return task.resources.summary }
        let limit = ResourcePlanner.gigabytes(task.resources.memoryMB)
        let usedText = used.memoryMB >= 1024 ? ResourcePlanner.gigabytes(used.memoryMB).replacingOccurrences(of: " GB", with: "") : ResourcePlanner.gigabytes(used.memoryMB)
        return "\(usedText) of \(limit) · \(task.resources.cpus) CPU"
    }

    var github: (value: String, elevated: Bool) {
        if task.access?.github == true { return ("Can push", true) }
        if task.githubAccess { return ("Can reach", true) }
        return ("None", false)
    }

    var account: (value: String, elevated: Bool) {
        switch task.access?.credential {
        case .claudeToken?: ("Subscription", false)
        case .apiKey?: ("API key", true)
        case nil: ("Unknown", false)
        }
    }

    func detail(_ kind: Permission.Kind) -> String? {
        task.permissions.first { $0.kind == kind }?.detail
    }
}

// MARK: Info

struct InfoTab: View {
    @Environment(AppModel.self) private var model
    let task: AgentTask
    @State private var addingTag = false
    @State private var showTechnical = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection(title: "Task") {
                InspectorRow(label: "Project", value: model.project(for: task)?.name ?? task.repo.name)
                if !task.workspace.branch.isEmpty {
                    InspectorRow(label: "Branch", value: task.workspace.branch, mono: true, help: task.workspace.branch)
                }
                InspectorRow(label: "Started", value: "\(task.origin?.isChat == true ? "From chat" : "Here"), \(StartTime.short(task.createdAt))",
                             help: task.createdAt.formatted(date: .long, time: .shortened))
                InspectorRow(label: "Runs on", value: task.runtime.displayName)
            if let tools = task.stack?.summary {
                InspectorRow(label: "Tools", value: tools,
                             help: task.stack?.configSource.map { "Detected, adjusted by \($0)" } ?? "Detected from the repository")
            }
            }
            InspectorSection(title: "Files") {
                InspectorRow(label: "Workspace", value: workspace, help: task.workspace.hostPath)
            }
            if let path = task.workspace.hostPath {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    .controlSize(.small)
                    .padding(.top, 10)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Tags").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(task.tags, id: \.self) { tag in
                        TagChip(tag: tag) { model.perform { try await $0.setTags(task.id, remove: [tag]) } }
                    }
                    Button { addingTag = true } label: { Image(systemName: "plus") }
                        .controlSize(.small)
                        .help("Add a tag")
                        .popover(isPresented: $addingTag, arrowEdge: .bottom) { AddTagPopover(task: task) { addingTag = false } }
                }
            }
            .padding(.top, 18)
            DisclosureGroup("Technical details", isExpanded: $showTechnical) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
                    technical("Task ID", task.shortID)
                    technical("Base", "\(task.repo.baseRef) \(task.workspace.baseCommit?.prefix(10) ?? "")")
                    technical("Container", task.containerID.map { String($0.prefix(12)) } ?? "—")
                    technical("Image", task.imageRef ?? "—")
                    technical("Path", task.repo.path)
                }
                .padding(.top, 6)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.top, 20)
        }
    }

    var workspace: String {
        let mode = task.workspace.mode == .worktree ? "Own worktree" : "Isolated clone"
        return task.repo.isPlainFolder ? "\(mode) of a folder" : mode
    }

    func technical(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}

struct AddTagPopover: View {
    @Environment(AppModel.self) private var model
    let task: AgentTask
    let done: () -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("New tag", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { add(draft) }
            let suggestions = model.allTags.filter { !task.tags.contains($0) && (draft.isEmpty || $0.contains(draft.lowercased())) }
            ForEach(suggestions.prefix(8), id: \.self) { tag in
                Button { add(tag) } label: { TagChip(tag: tag) }.buttonStyle(.plain)
            }
        }
        .padding(12)
    }

    func add(_ tag: String) {
        guard Tag.normalize(tag) != nil else { return }
        model.perform { try await $0.setTags(task.id, add: [tag]) }
        done()
    }
}

/// Wraps its children onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in arrange(width: bounds.width, subviews: subviews).points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, CGSize(width: widest, height: y + lineHeight))
    }
}

extension ServiceInstance.State {
    /// For a row with little room: "Starting", "Failed", "Stopped".
    var shortTitle: String {
        switch self {
        case .failed: "Failed"
        default: title
        }
    }
}
