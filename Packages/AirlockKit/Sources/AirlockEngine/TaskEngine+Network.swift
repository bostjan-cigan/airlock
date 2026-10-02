import AirlockCore
import AirlockProviders
import AirlockRuntime
import Foundation

/// The result of changing a task's allowlist.
public struct NetworkChange: Codable, Sendable, Equatable {
    /// The task's own allowed hosts afterwards (not counting the agent's built-in ones).
    public var allowed: [String]
    /// Entries the firewall found no addresses for.
    public var unresolved: [String]
    /// The running container's firewall was updated; otherwise it applies at the next start.
    public var applied: Bool

    public init(allowed: [String], unresolved: [String], applied: Bool) {
        self.allowed = allowed
        self.unresolved = unresolved
        self.applied = applied
    }
}

extension TaskEngine {
    /// Hosts every restricted task of this kind can reach without being asked: the agent's
    /// own, and GitHub's when the task opted in.
    public nonisolated func builtInHosts(for task: AgentTask) -> [String] {
        let provider = Providers.provider(for: task.providerID)
        return (provider?.defaultAllowlist ?? []) + (task.githubAccess ? NetworkRules.githubHosts : [])
    }

    /// Adds and removes hosts on a restricted task's allowlist. A running task's firewall is
    /// updated right away, along with its services, which share its network.
    @discardableResult
    public func setAllowedHosts(_ id: UUID, add: [String] = [], remove: [String] = [], by source: String = "you") async throws -> NetworkChange {
        guard let task = tasks[id] else { throw EngineError("No such task.") }
        guard !task.isInspection else { throw EngineError("An inspection's network stays closed; nothing can be allowed.") }
        guard case .restricted(let current) = task.network else {
            throw EngineError("This task has an open network, so every host is already reachable.")
        }
        let adding = try add.map(NetworkRules.normalize)
        let removing = Set(try remove.map(NetworkRules.normalize))
        let list = NetworkRules.merge(current.filter { !removing.contains($0) }, adding)
        update(id) {
            $0.network = .restricted(extraDomains: list)
            $0.blockedHosts.removeAll { adding.contains($0.name) }
            $0.ignoredHosts.removeAll { adding.contains($0) }
        }
        let updated = tasks[id]!
        _ = try writeNetworkConfig(updated, provider: try provider(for: updated))

        let added = adding.filter { !current.contains($0) }
        let removed = current.filter { removing.contains($0) }
        if !added.isEmpty { log(id, "Allowed \(added.joined(separator: ", ")) (\(source))") }
        if !removed.isEmpty { log(id, "Removed \(removed.joined(separator: ", ")) from the allowlist (\(source))") }

        guard updated.lifecycle == .running, let containerID = updated.containerID, let runtime = runtimes[updated.runtime] else {
            return NetworkChange(allowed: list, unresolved: [], applied: false)
        }
        // Only the task's own entries: a built-in host without addresses isn't the user's to fix.
        let unresolved = try await applyFirewall(updated, runtime: runtime, containerID: containerID).filter(list.contains)
        return NetworkChange(allowed: list, unresolved: unresolved, applied: true)
    }

    /// The user declined these blocked hosts: stop reporting them for this task.
    public func ignoreBlockedHosts(_ id: UUID, _ names: [String]) {
        update(id) { task in
            let declined = Set(names.compactMap { try? NetworkRules.normalize($0) })
            task.blockedHosts.removeAll { declined.contains($0.name) }
            task.ignoredHosts = NetworkRules.merge(task.ignoredHosts, Array(declined))
        }
    }

    /// Adds and removes hosts new tasks in a project start with.
    @discardableResult
    public func setProjectHosts(_ projectID: UUID, add: [String] = [], remove: [String] = []) throws -> Project {
        guard let index = projectList.firstIndex(where: { $0.id == projectID }) else { throw EngineError("No such project.") }
        let adding = try add.map(NetworkRules.normalize)
        let removing = Set(try remove.map(NetworkRules.normalize))
        projectList[index].allowedHosts = NetworkRules.merge(projectList[index].allowedHosts.filter { !removing.contains($0) }, adding)
        saveProjects()
        return projectList[index]
    }

    // MARK: Firewall

    /// Hands the container's firewall the task's current allowlist; returns entries it couldn't resolve.
    func applyFirewall(_ task: AgentTask, runtime: any ContainerRuntime, containerID: String) async throws -> [String] {
        let json = String(decoding: try Self.networkConfig(task, provider: try provider(for: task)), as: UTF8.self)
        let script = """
        grep -q /run/airlock/network.json /usr/local/bin/airlock-firewall || exit 42
        mkdir -p /run/airlock && printf '%s' "$AIRLOCK_NETWORK_JSON" > /run/airlock/network.json && /usr/local/bin/airlock-firewall
        """
        let result = try await runtime.exec(containerID, ExecSpec(["sh", "-c", script], user: "root", environment: ["AIRLOCK_NETWORK_JSON": json]))
        if result.exitCode == 42 {
            throw EngineError("This task's container predates live network changes. The new list applies when the task is started from scratch.")
        }
        guard result.exitCode == 0 else {
            throw EngineError("Couldn't update the firewall: \((result.errorOutput + result.output).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return Self.unresolvedEntries(result.output + result.errorOutput)
    }

    static func unresolvedEntries(_ output: String) -> [String] {
        let marker = "airlock-firewall: no addresses for "
        return output.split(separator: "\n").compactMap { line in
            line.hasPrefix(marker) ? String(line.dropFirst(marker.count)) : nil
        }
    }

    // MARK: Blocked hosts

    func resetDNSLog(_ id: UUID) {
        dnsOffsets[id] = nil
        dnsReaders[id] = nil
    }

    /// Reads what the agent looked up since last time and records the names that resolved
    /// only to addresses the firewall refuses.
    func scanBlockedHosts(_ id: UUID, runtime: any ContainerRuntime, containerID: String) async {
        guard let task = tasks[id], case .restricted(let extras) = task.network else { return }
        let offset = dnsOffsets[id] ?? 0
        let read = """
        f=/run/airlock/dns.log
        [ -f "$f" ] || exit 3
        size=$(stat -c %s "$f"); from=$OFFSET
        [ "$size" -lt "$from" ] && from=0
        echo "$from $size"
        tail -c +$((from + 1)) "$f" | head -c $((size - from))
        """
        guard let result = try? await runtime.exec(containerID, ExecSpec(["sh", "-c", read], user: "root", environment: ["OFFSET": "\(offset)"])),
              result.exitCode == 0 else { return }
        let output = result.output
        guard let firstNewline = output.firstIndex(of: "\n") else { return }
        let header = output[..<firstNewline].split(separator: " ").compactMap { Int($0) }
        guard header.count == 2 else { return }
        if header[0] == 0, offset != 0 { dnsReaders[id] = DNSLogReader() }
        dnsOffsets[id] = header[1]
        var reader = dnsReaders[id] ?? DNSLogReader()
        let lookups = reader.read(String(output[output.index(after: firstNewline)...]))
        dnsReaders[id] = reader

        let allowed = Set(builtInHosts(for: task) + extras)
        let ignored = Set(task.ignoredHosts + (Providers.provider(for: task.providerID)?.backgroundHosts ?? []))
        // Names without a dot are local (service names, search domains), never internet hosts.
        // The agent picks the names it looks up, and they're shown and relayed: real hostnames only.
        let candidates = lookups.filter {
            $0.name.contains(".") && UntrustedText.isHostname($0.name) && !ignored.contains($0.name) && !Self.covered($0.name, by: ignored)
        }
        var newlyBlocked: [String: Int] = [:]
        // Refused by the resolver's allowlist policy: blocked, no need to check addresses.
        for lookup in candidates where lookup.refused && !Self.covered(lookup.name, by: allowed) {
            newlyBlocked[lookup.name, default: 0] += 1
        }
        let relevant = candidates.compactMap { lookup -> DNSLogReader.Lookup? in
            let addresses = lookup.addresses.filter { !$0.hasPrefix("127.") && $0 != "::1" }
            return lookup.refused || addresses.isEmpty ? nil : DNSLogReader.Lookup(name: lookup.name, addresses: addresses)
        }

        let reachable = relevant.isEmpty ? [] : await reachableAddresses(Set(relevant.flatMap(\.addresses)), runtime: runtime, containerID: containerID)
        var allowlistedMoved = false
        for lookup in relevant where !lookup.addresses.contains(where: reachable.contains) {
            if Self.covered(lookup.name, by: allowed) {
                allowlistedMoved = true
            } else {
                newlyBlocked[lookup.name, default: 0] += 1
            }
        }
        if allowlistedMoved, (firewallRefreshed[id].map { Date.now.timeIntervalSince($0) > 60 } ?? true) {
            // A CDN moved an allowed host to new addresses: re-resolve now rather than in five minutes.
            firewallRefreshed[id] = .now
            _ = try? await applyFirewall(task, runtime: runtime, containerID: containerID)
        }
        guard !newlyBlocked.isEmpty else { return }

        // An inspection only records what its code tried: nothing to allow, nobody to ask.
        if task.isInspection, task.inspection?.report != nil {
            update(id) { task in
                let known = Set(task.inspection?.report?.triedHosts ?? [])
                task.inspection?.report?.triedHosts += newlyBlocked.keys.sorted().filter { !known.contains($0) }
            }
            return
        }
        if task.isInspection {
            update(id) { task in
                for (name, count) in newlyBlocked where !task.blockedHosts.contains(where: { $0.name == name }) {
                    task.blockedHosts.append(BlockedHost(name: name, attempts: count))
                }
            }
            return
        }

        let before = Set(task.blockedHosts.map(\.name))
        update(id) { task in
            for (name, count) in newlyBlocked.sorted(by: { $0.key < $1.key }) {
                if let index = task.blockedHosts.firstIndex(where: { $0.name == name }) {
                    task.blockedHosts[index].attempts += count
                    task.blockedHosts[index].lastSeen = .now
                } else {
                    task.blockedHosts.append(BlockedHost(name: name, attempts: count))
                }
            }
        }
        let fresh = tasks[id]!.blockedHosts.filter { !before.contains($0.name) }
        if !fresh.isEmpty {
            log(id, "Blocked \(fresh.map(\.name).joined(separator: ", "))")
            updateSink.yield(.blocked(tasks[id]!, fresh))
        }
    }

    /// A host is allowed by its own entry or a parent domain's: "pypi.org" covers "upload.pypi.org".
    static func covered(_ name: String, by hosts: Set<String>) -> Bool {
        var labels = name.split(separator: ".")
        while labels.count >= 2 {
            if hosts.contains(labels.joined(separator: ".")) { return true }
            labels.removeFirst()
        }
        return false
    }

    /// Which of these addresses the firewall lets through.
    private func reachableAddresses(_ addresses: Set<String>, runtime: any ContainerRuntime, containerID: String) async -> Set<String> {
        let check = """
        for ip in $ADDRESSES; do
            case "$ip" in *:*) set=allowed6 ;; *) set=allowed4 ;; esac
            nft get element inet airlock "$set" "{ $ip }" >/dev/null 2>&1 && echo "$ip"
        done
        exit 0
        """
        guard let result = try? await runtime.exec(containerID, ExecSpec(["sh", "-c", check], user: "root",
                                                                         environment: ["ADDRESSES": addresses.sorted().joined(separator: " ")])),
              result.exitCode == 0 else { return addresses }
        return Set(result.output.split(separator: "\n").map(String.init))
    }
}
