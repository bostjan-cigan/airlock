import AirlockCore
import AirlockEngine
import AirlockProviders
import AirlockRuntime
import Foundation

/// Inspects a small sample repository end to end: download with scripts off, the network
/// closes, its postinstall runs, and the report shows what it did. The sample's postinstall
/// only touches harmless things the recorder should notice.
enum EndToEndInspect {
    static func run(runtime: any ContainerRuntime, scratch: URL) async throws {
        let root = scratch.appending(path: "e2e-inspect-\(Int(Date().timeIntervalSince1970))")
        let repo = root.appending(path: "sample")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try """
        {
          "name": "airlock-inspect-sample",
          "version": "1.0.0",
          "dependencies": { "is-number": "7.0.0" },
          "scripts": { "postinstall": "cat ~/.npmrc > /dev/null; touch /tmp/airlock-e2e-marker; curl -s -m 3 https://example.com > /dev/null; true" }
        }
        """.write(to: repo.appending(path: "package.json"), atomically: true, encoding: .utf8)
        // A config file that would point npm somewhere else, if it were used for the download.
        try "registry=https://registry.invalid/\n".write(to: repo.appending(path: ".npmrc"), atomically: true, encoding: .utf8)

        let engine = TaskEngine(paths: Paths(root: root.appending(path: "support")), secrets: InMemorySecretStore([:]),
                                runtimes: [runtime.kind: runtime])
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }

        let task = try await engine.createInspection(InspectionRequest(source: .folder(repo.path), runtime: runtime.kind))
        try await EndToEnd.waitFor("inspection report", timeout: 1200) {
            guard let t = await engine.task(task.id) else { return false }
            if case .failed(let m) = t.lifecycle { throw EngineError(m) }
            return t.inspection?.phase == .finished
        }
        let done = await engine.task(task.id)!
        guard let report = done.inspection?.report else { throw EngineError("No report") }
        print("  \(report.summary)")
        check("downloaded with scripts off", report.downloads.contains { $0.contains("--ignore-scripts") } && !report.downloadFailed,
              report.downloads.joined(separator: "; "))
        check("its postinstall ran after the network closed", report.command.contains("postinstall") && report.exitCode == 0, report.command)
        check("decoy credential read recorded", report.credentialReads.contains("~/.npmrc"), report.credentialReads.joined(separator: ", "))
        check("file written outside the repository recorded", report.changedOutside.contains("/tmp/airlock-e2e-marker"), report.changedOutside.joined(separator: ", "))
        check("lookup recorded and refused", report.triedHosts.contains("example.com"), report.triedHosts.joined(separator: ", "))
        check("no credentials in the VM", done.access?.credential == nil)

        let id = done.containerID!
        func sh(_ cmd: String, user: String = "node") async throws -> ExecResult {
            try await runtime.exec(id, ExecSpec(["sh", "-c", cmd], user: user, workdir: "/workspace"))
        }
        let installed = try await sh("test -f node_modules/is-number/package.json && echo yes")
        check("dependency installed from the registry", installed.output.contains("yes"), installed.errorOutput)
        let closed = try await sh("curl -sS -m 5 -o /dev/null https://registry.npmjs.org")
        check("network closed afterwards", closed.exitCode != 0, "exit \(closed.exitCode)")
        let mounts = try await sh("grep -E ' /(workspace|airlock|home)' /proc/mounts | awk '{print $2}' | sort | tr '\\n' ' '", user: "root")
        check("nothing of the Mac mounted but the network file", !mounts.output.contains("/airlock/events") && !mounts.output.contains(".claude"),
              mounts.output)
        let widen = (try? await engine.setAllowedHosts(task.id, add: ["example.com"])) == nil
        check("the network can't be widened", widen)
        let back = (try? await engine.bringBack(task.id)) == nil
        check("nothing comes back out", back)

        await engine.stop(task.id)
        await engine.start(task.id)
        try await EndToEnd.waitFor("restart", timeout: 120) { await engine.task(task.id)?.lifecycle == .running }
        let stillClosed = try await sh("curl -sS -m 5 -o /dev/null https://registry.npmjs.org")
        check("still closed after a restart", stillClosed.exitCode != 0, "exit \(stillClosed.exitCode)")

        try await engine.remove(task.id)
        check("removed", (try? await runtime.state(id)) == .missing)
        try? FileManager.default.removeItem(at: root)
    }
}
