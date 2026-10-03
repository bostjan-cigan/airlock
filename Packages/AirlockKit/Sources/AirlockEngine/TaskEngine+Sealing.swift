import AirlockCore
import AirlockProviders
import AirlockRuntime
import Foundation

/// A sealed coding task: its dependencies are downloaded with install scripts off, the network
/// closes, then the install scripts run (recorded), and only then does the agent start. The
/// agent reaches Claude through the credential proxy and nothing else, until the user allows
/// a host it asks for.
extension TaskEngine {
    /// Decoys for a coding task: not the files its own tools read (git reads ~/.netrc).
    static let codingDecoys = ".ssh/id_rsa .ssh/id_ed25519 .aws/credentials .npmrc .pypirc .docker/config.json .kube/config"

    func sealedSetup(_ id: UUID, runtime: any ContainerRuntime, containerID: String) async throws {
        guard tasks[id]?.sealing != nil else { return }
        let node = ContainerPaths.user
        let decoys = ["AIRLOCK_DECOYS": Self.codingDecoys]
        setSealPhase(id, .downloading)

        var report = InspectionReport()
        let download = try await runtime.exec(containerID, ExecSpec(["/usr/local/bin/airlock-inspect", "download"], user: node, workdir: ContainerPaths.workspace))
        for line in (download.output + "\n" + download.errorOutput).split(separator: "\n") {
            log(id, UntrustedText.oneLine(String(line), limit: 400))
            if line.hasPrefix("step: ") { report.downloads.append(UntrustedText.oneLine(String(line.dropFirst(6)))) }
        }
        report.downloadFailed = download.exitCode != 0
        await scanBlockedHosts(id, runtime: runtime, containerID: containerID)
        update(id) { $0.blockedHosts = [] }

        // Closed, and checked, before any dependency code runs.
        setSealPhase(id, .sealed)
        guard let sealed = tasks[id] else { return }
        _ = try writeNetworkConfig(sealed, provider: try provider(for: sealed))
        _ = try await applyFirewall(sealed, runtime: runtime, containerID: containerID)
        let probe = try await runtime.exec(containerID, ExecSpec(
            ["sh", "-c", "getent hosts registry.npmjs.org >/dev/null || curl -s -m 5 -o /dev/null https://1.1.1.1"], user: node))
        guard probe.exitCode != 0 else { throw EngineError("The network didn't close, so the install scripts weren't run.") }
        _ = try await runtime.exec(containerID, ExecSpec(["/usr/local/bin/airlock-inspect", "decoys"], user: node, environment: decoys))
        try await runtime.run(containerID, ExecSpec(["/usr/local/bin/airlock-inspect", "seal"], user: "root"))
        update(id) { $0.sealing?.sealedAt = .now }

        log(id, "Running install scripts with the network closed")
        let run = try await runtime.exec(containerID, ExecSpec(["/usr/local/bin/airlock-inspect", "run"], user: node, workdir: ContainerPaths.workspace))
        let printed = run.output + (run.errorOutput.isEmpty ? "" : "\n" + run.errorOutput)
        if let first = printed.split(separator: "\n").first, first.hasPrefix("run: ") {
            report.command = UntrustedText.oneLine(String(first.dropFirst(5)), limit: 600)
        }
        report.exitCode = run.exitCode
        report.output = UntrustedText.block(String(printed.suffix(6000)), limit: 6000)
        try await Task.sleep(for: .seconds(2))
        let tree = try await runtime.exec(containerID, ExecSpec(["/usr/local/bin/airlock-inspect", "tree"], user: node))
        let seen = try await runtime.exec(containerID, ExecSpec(["/usr/local/bin/airlock-inspect", "report"], user: "root", environment: decoys))
        // The agent's own changes are its work; what setup changed in the repository is expected.
        Self.read(tree.output.split(separator: "\n").filter { !$0.hasPrefix("repo ") }.joined(separator: "\n") + "\n" + seen.output, into: &report)
        await scanBlockedHosts(id, runtime: runtime, containerID: containerID)
        report.triedHosts = tasks[id]?.blockedHosts.map(\.name) ?? []
        let finalReport = report
        update(id) {
            $0.blockedHosts = []
            $0.sealing?.report = finalReport
        }
        log(id, "Setup: \(report.summary)")
        if report.findings > 0 { attention(id, .notification, "Setup: \(report.summary)") }
    }

    func setSealPhase(_ id: UUID, _ phase: Sealing.Phase) {
        update(id) {
            $0.sealing?.phase = phase
            $0.activity = .working(tool: phase.title)
        }
        log(id, phase.title)
    }

    /// Decoy credentials something in a sealed task read since setup: checked while it runs,
    /// so a package that waits, or the agent being talked into it, shows up too.
    func checkDecoyReads(_ id: UUID, runtime: any ContainerRuntime, containerID: String) async {
        guard let task = tasks[id], task.sealing?.sealedAt != nil, task.sealing?.report != nil,
              let result = try? await runtime.exec(containerID, ExecSpec(["/usr/local/bin/airlock-inspect", "reads"], user: "root",
                                                                        environment: ["AIRLOCK_DECOYS": Self.codingDecoys])),
              result.exitCode == 0 else { return }
        var report = InspectionReport()
        Self.read(result.output, into: &report)
        let known = Set(task.sealing?.report?.credentialReads ?? [])
        let fresh = report.credentialReads.filter { !known.contains($0) }
        guard !fresh.isEmpty else { return }
        update(id) { $0.sealing?.report?.credentialReads += fresh }
        attention(id, .notification, "Something in the task read \(fresh.joined(separator: ", ")), a decoy credential")
    }
}
