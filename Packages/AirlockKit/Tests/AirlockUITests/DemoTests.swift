import AirlockCore
import AirlockEngine
import Foundation
import Testing
@testable import AirlockUI

@MainActor
@Suite struct DemoTests {
    @Test func demoShowsEveryStateAndAllowsHosts() async throws {
        let model = AppModel.demo()
        let engine = model.engine
        defer { try? FileManager.default.removeItem(at: engine.paths.root) }
        let tasks = await engine.bootstrap()
        func task(_ title: String) throws -> AgentTask { try #require(tasks.first { $0.title == title }) }

        let statuses = Set(tasks.map(\.status))
        for status in [TaskStatus.needsInput, .failed, .working, .ready, .exited, .stopped, .done] {
            #expect(statuses.contains(status), "no demo task is \(status)")
        }
        #expect(try task("Refactor OAuth schema").statusDetail == "Splitting oauth_tokens rewrites 1.2M rows. Backfill in batches behind a flag, or in one migration during a maintenance window?")
        let blocked = try task("Add OpenTelemetry tracing")
        #expect(blocked.status == .needsInput)
        #expect(blocked.statusDetail == "Blocked api.honeycomb.io and 1 other")
        let working = try task("Pen-test the OAuth endpoints")
        #expect(working.status == .working && working.services?.items.count == 2)
        #expect(await engine.events(for: working.id).currentMilestone == "Fuzz /oauth/token with malformed grants (2/5 done)")
        #expect(try await engine.changes(working.id).files.map(\.path) == ["SECURITY.md"])
        guard case .idle(let reply) = try task("Fix flaky checkout e2e test").activity else { Issue.record("not ready"); return }
        #expect(reply?.hasPrefix("The test read the order total") == true)
        #expect(try task("Publish SDK 3.0 to npm").hasElevatedAccess)
        #expect(try task("Compress hero images").repo.isPlainFolder)

        // Detected stacks, sizes, a base branch that moved on, and an Xcode notice.
        #expect(try task("Fix flaky checkout e2e test").stack?.summary == "Node 22")
        #expect(try task("Fuzz the query parser").stack?.summary == "Rust 1.90")
        #expect(working.resourceReason == "auto")
        #expect(await engine.baseUpdates(working.id) == 1)
        #expect(try task("Adopt Liquid Glass in Settings").stack?.notices.first?.contains("Apple-platform") == true)
        let usage = try await DemoRuntime(kind: .docker).usage("demo-x")
        #expect((usage?.memoryBytes ?? 0) > 0)

        // Allowing what was blocked clears it and the task is simply ready again.
        let change = try await engine.setAllowedHosts(blocked.id, add: ["api.honeycomb.io", "otel-collector.internal"])
        #expect(change.applied)
        let after = try #require(await engine.task(blocked.id))
        #expect(after.blockedHosts.isEmpty && after.status == .ready)
        #expect(change.allowed.contains("api.honeycomb.io"))
    }
}
