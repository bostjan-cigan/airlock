import AirlockCore
import AppKit
import SwiftUI

/// Scopes: smart lists, projects and tags. Picking one fills the task list.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding<SidebarScope?>(get: { model.scope }, set: { if let s = $0 { model.scope = s } })) {
            Section {
                ScopeRow(title: "Active", icon: "bolt", count: model.count(.active))
                    .tag(SidebarScope.active)
                ScopeRow(title: "Needs you", icon: "exclamationmark.circle", count: model.count(.needsYou))
                    .tag(SidebarScope.needsYou)
                ScopeRow(title: "All tasks", icon: "tray.full", count: nil)
                    .tag(SidebarScope.all)
            }

            Section {
                ForEach(model.sortedProjects) { project in
                    ScopeRow(title: project.name, icon: "folder", count: model.count(.project(project.id)),
                             secondary: model.repoIsShared(project) ? project.repoName : nil)
                        .tag(SidebarScope.project(project.id))
                        .help(project.repoPath)
                        .contextMenu { ProjectActions(project: project) }
                }
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    Button { model.isPresentingNewProject = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New project")
                }
            }

            if !model.allTags.isEmpty {
                Section("Tags") {
                    ForEach(model.allTags, id: \.self) { tag in
                        Label(tag, systemImage: "tag")
                        .tag(SidebarScope.tag(tag))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct ScopeRow: View {
    let title: String
    let icon: String
    let count: Int?
    var secondary: String?

    var body: some View {
        // The sidebar colors the icon itself: accent normally, white when selected.
        Label {
            // The name wins the space; the repository is only there to tell projects apart.
            HStack(spacing: 4) {
                Text(title).lineLimit(1).layoutPriority(1)
                if let secondary, secondary.caseInsensitiveCompare(title) != .orderedSame {
                    Text(secondary).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: icon)
        }
        .badge(count ?? 0)
    }
}

struct ProjectActions: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        Button("Rename…") {
            let alert = NSAlert()
            alert.messageText = "Rename project"
            let field = NSTextField(string: project.name)
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: "Rename")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            if alert.runModal() == .alertFirstButtonReturn {
                let name = field.stringValue
                model.perform { try await $0.renameProject(project.id, to: name) }
            }
        }
        Button("Network Defaults…") { model.networkEditor = .project(project.id) }
        Button("Open repository in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: project.repoPath)) }
        Divider()
        Button("Delete project…", role: .destructive) {
            let alert = NSAlert()
            alert.messageText = "Delete “\(project.name)”?"
            alert.informativeText = "All of its tasks are stopped and deleted, along with their containers and workspaces. Task branches in the repository are kept; in a plain folder, each task's work is applied to its files."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[0].hasDestructiveAction = true
            if alert.runModal() == .alertFirstButtonReturn {
                model.perform { try await $0.deleteProject(project.id) }
            }
        }
    }
}
