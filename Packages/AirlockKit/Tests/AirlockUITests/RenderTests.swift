import AirlockCore
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AirlockUI

/// Renders the main views from demo data to PNGs, for looking at the design without the
/// app: `AIRLOCK_RENDER_DIR=/some/dir swift test --filter RenderTests`.
@MainActor
@Suite struct RenderTests {
    @Test func renderViews() async throws {
        guard let dir = ProcessInfo.processInfo.environment["AIRLOCK_RENDER_DIR"] else { return }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let model = AppModel.demo()
        defer { try? FileManager.default.removeItem(at: model.engine.paths.root) }
        for task in await model.engine.bootstrap() { model.apply(.task(task)) }
        for project in await model.engine.projects() { _ = project }
        model.apply(.projects(await model.engine.projects()))
        for id in model.tasks.keys { model.apply(.events(id, await model.engine.events(for: id))) }

        func save<V: View>(_ name: String, width: CGFloat, _ view: V) {
            let renderer = ImageRenderer(content: view.environment(model).frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: out.appending(path: "\(name).png"))
        }
        func task(_ title: String) -> AgentTask { model.tasks.values.first { $0.title == title }! }

        let rows = model.tasks.values.sorted { $0.createdAt > $1.createdAt }
        save("list", width: 320, VStack(spacing: 0) { ForEach(rows) { TaskRow(task: $0).padding(.horizontal, 10); Divider() } })
        for title in ["Add CSV export", "Add Python report generator", "Publish API client to npm", "Refactor billing webhooks"] {
            let t = task(title)
            save("header-\(t.shortID)", width: 620, VStack(spacing: 16) {
                TaskHeader(task: t) {}
                BlockedBanner(task: t)
            }.padding(24))
        }
        // The header stays at the top on a tab whose content is short.
        save("detail-changes", width: 640, TaskDetailColumn(task: task("Choose date format for exports"), tab: .constant(.changes)) {}.frame(height: 640))

        // ImageRenderer can't draw a ScrollView, so each tab's content is drawn as the inspector lays it out.
        func inspector(_ t: AgentTask, _ tab: InspectorTab) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                InspectorTabBar(selection: .constant(tab)).padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
                Divider()
                Group {
                    switch tab {
                    case .containers: ContainersTab(task: t)
                    case .access: AccessTab(task: t)
                    case .info: InfoTab(task: t)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        var busy = task("Add CSV export")
        busy.services?.items += [
            ServiceInstance(name: "minio", image: "minio/minio", containerID: "demo-minio", state: .running, ports: [9001]),
            ServiceInstance(name: "mailpit", image: "axllent/mailpit", containerID: "demo-mail", state: .healthy, ports: [8025]),
            ServiceInstance(name: "search", image: "opensearch:2", containerID: "demo-search", state: .starting),
        ]
        busy.ports += [PortForward(containerPort: 9001, hostPort: 9001, service: "minio"), PortForward(containerPort: 8025, hostPort: 8025, service: "mailpit")]
        model.apply(.usage(busy.id, ["agent": .init(cpuPercent: 42, memoryBytes: 1_288_490_188), "postgres": .init(cpuPercent: 3, memoryBytes: 220_000_000)]))
        for tab in InspectorTab.allCases { save("inspector-\(tab.rawValue)", width: 290, inspector(busy, tab)) }
        save("inspector-access-elevated", width: 290, inspector(task("Publish API client to npm"), .access))
    }
}
