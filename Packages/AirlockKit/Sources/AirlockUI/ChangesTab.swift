import AirlockCore
import AirlockEngine
import AirlockWorkspace
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChangesTab: View {
    @Environment(AppModel.self) private var model
    let task: AgentTask
    @State private var changes: WorkspaceChanges?
    @State private var selectedFile: String?
    @State private var loading = false
    @State private var message: String?
    /// New commits on the base branch since the task started.
    @State private var baseAhead = 0

    var body: some View {
        VStack(spacing: 0) {
            if baseAhead > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.merge").foregroundStyle(.secondary)
                    Text("\(task.repo.baseRef) has \(baseAhead) new commit\(baseAhead == 1 ? "" : "s")")
                    Spacer()
                    Button("Update") { Task { await updateFromBase() } }
                        .help(task.lifecycle == .running
                              ? "Ask the agent to merge them and resolve any conflicts"
                              : "Merge them into the task branch; a conflict changes nothing")
                }
                .font(.system(size: 13))
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(.quaternary.opacity(0.35))
                Divider()
            }
            // Only once there's something to act on; until then the empty state says it all.
            if let changes, !changes.files.isEmpty {
                HStack(spacing: 8) {
                    Text("\(changes.files.count) file\(changes.files.count == 1 ? "" : "s") changed · \(changes.commits.count) commit\(changes.commits.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                    if let message {
                        Text("·").foregroundStyle(.tertiary)
                        Text(message).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh")
                    Button("Export Patch…") { Task { await exportPatch() } }
                    Button("Hand Off…") { model.handoffSheet = TaskRef(task.id) }
                        .help(task.repo.isPlainFolder
                              ? "Review the work, then apply it to the files in \(task.repo.name)"
                              : "Review the work, then bring its branch into your repository")
                }
                .font(.system(size: 13))
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                Divider()
            }
            if let changes, !changes.files.isEmpty {
                // Side by side only when the column has room for both, stacked otherwise. Plain
                // stacks with no minimum width: split views' minimums aren't passed up to the
                // window, so a narrow column overflowed and pushed the sidebar and inspector off
                // screen, and switching between them near the threshold looped the layout.
                GeometryReader { geo in
                    let diff = DiffView(diff: fileDiff(changes.diff, path: selectedFile))
                    if geo.size.width >= 620 {
                        HStack(spacing: 0) {
                            fileList(changes).frame(width: min(260, geo.size.width * 0.35))
                            Divider()
                            diff
                        }
                    } else {
                        VStack(spacing: 0) {
                            fileList(changes).frame(height: min(150, geo.size.height * 0.35))
                            Divider()
                            diff
                        }
                    }
                }
            } else if changes != nil {
                ContentUnavailableView {
                    Label("No changes yet", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text(message ?? "Files the agent changes since \(task.repo.baseRef) appear here.")
                } actions: {
                    Button("Refresh") { Task { await load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: task.lifecycle) { await load() }
    }

    func fileList(_ changes: WorkspaceChanges) -> some View {
        List(changes.files, selection: $selectedFile) { file in
            HStack(spacing: 6) {
                Text(kindLetter(file.kind))
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(kindColor(file.kind))
                    .frame(width: 12)
                Text(file.path)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                if let a = file.additions { Text("+\(a)").foregroundStyle(.green) }
                if let d = file.deletions, d > 0 { Text("−\(d)").foregroundStyle(.red) }
            }
            .font(.callout)
            .tag(file.path)
        }
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            changes = try await model.engine.changes(task.id)
            baseAhead = await model.engine.baseUpdates(task.id)
            message = nil
        } catch {
            message = "Couldn't read changes: \(error)"
        }
    }

    func exportPatch() async {
        guard let patch = try? await model.engine.exportPatch(task.id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(task.workspace.branch.replacingOccurrences(of: "/", with: "-")).patch"
        panel.allowedContentTypes = [UTType(filenameExtension: "patch") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? patch.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func updateFromBase() async {
        do {
            switch try await model.engine.updateFromBase(task.id) {
            case .upToDate: message = "Already up to date"
            case .merged(let n): message = "Merged \(n) commit\(n == 1 ? "" : "s") from \(task.repo.baseRef)"
            case .askedAgent: message = "Asked the agent to merge \(task.repo.baseRef)"
            case .conflict(let files): message = "Conflicts in \(files.joined(separator: ", ")); nothing changed"
            }
            await load()
        } catch {
            message = String(describing: error)
        }
    }

    /// The part of a unified diff for one file (or everything when nil).
    func fileDiff(_ diff: String, path: String?) -> String {
        guard let path else { return diff }
        var out: [Substring] = []
        var inFile = false
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                inFile = line.hasSuffix(" b/\(path)")
            }
            if inFile { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    func kindLetter(_ kind: FileChange.Kind) -> String {
        switch kind {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "U"
        }
    }

    func kindColor(_ kind: FileChange.Kind) -> Color {
        switch kind {
        case .added, .untracked: .green
        case .deleted: .red
        default: .orange
        }
    }
}

struct DiffView: View {
    let diff: String

    var body: some View {
        // Lines never wrap: long ones scroll sideways, and the row tints span at least the
        // visible width so short diffs still read as full rows.
        GeometryReader { geo in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : String(line))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(color(line))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(line))
                    }
                }
                .padding(.vertical, 8)
                // At least the visible size, pinned to the top left: a short diff would
                // otherwise sit in the middle of the scroll view.
                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                .textSelection(.enabled)
            }
        }
    }

    func color(_ line: Substring) -> Color {
        if line.hasPrefix("@@") { return .blue }
        if line.hasPrefix("diff --git") || line.hasPrefix("index ") || line.hasPrefix("+++") || line.hasPrefix("---") { return .secondary }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        return .primary
    }

    func background(_ line: Substring) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return .green.opacity(0.08) }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return .red.opacity(0.08) }
        return .clear
    }
}
