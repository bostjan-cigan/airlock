import AirlockCore
import AppKit
import SwiftUI

public struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    public init() {}

    public var body: some View {
        let waiting = model.needsYou.count
        HStack(spacing: 3) {
            Image(systemName: waiting > 0 ? "shippingbox.and.arrow.backward.fill" : "shippingbox")
            if model.runningCount + waiting > 0 { Text("\(model.runningCount + waiting)") }
        }
        // The label is always alive, so it opens the window for notification clicks too.
        .onChange(of: model.windowRequest) {
            openWindow(id: "main")
            NSApp.activate()
        }
    }
}

public struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AIrlock").font(.headline)
                Spacer()
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            let waiting = model.needsYou
            let running = model.running
            if waiting.isEmpty && running.isEmpty {
                Text("Nothing running")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            if !waiting.isEmpty { section("Needs you", waiting) }
            if !running.isEmpty { section("Running", running) }
            if model.keepsMacAwake {
                Label("Keeping your Mac awake while tasks run", systemImage: "cup.and.saucer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
            Divider().padding(.vertical, 4)
            menuButton("Open AIrlock") { model.openWindow() }
            menuButton("New task…") {
                model.openWindow()
                model.isPresentingNewTask = true
            }
            menuButton("Quit AIrlock") { NSApp.terminate(nil) }
        }
        .padding(.vertical, 4)
        .frame(width: 300)
    }

    var summary: String {
        let parts = [
            model.runningCount > 0 ? "\(model.runningCount) running" : nil,
            model.needsYou.isEmpty ? nil : "\(model.needsYou.count) need\(model.needsYou.count == 1 ? "s" : "") you",
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    func section(_ title: String, _ tasks: [AgentTask]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 2)
            ForEach(tasks) { task in
                Button { model.reveal(task.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        StatusIndicator(task: task).frame(width: 12)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(task.title).lineLimit(1)
                            Text([model.project(for: task)?.name, task.simpleStatus].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
    }

    func menuButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
