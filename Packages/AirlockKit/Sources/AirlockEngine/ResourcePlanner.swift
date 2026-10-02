import AirlockCore
import Foundation

/// How big a task's container is, and why.
public struct ResourcePlan: Codable, Sendable, Equatable {
    public var limits: ResourceLimits
    /// "auto", "auto, Rust", "set for this task", "project default", ".airlock/compose.yaml".
    public var reason: String
    /// Set when this task and the ones already running would crowd the Mac.
    public var warning: String?

    public init(limits: ResourceLimits, reason: String, warning: String? = nil) {
        self.limits = limits
        self.reason = reason
        self.warning = warning
    }
}

/// Picks a container's CPU and memory. An explicit size wins, then the project's default,
/// then its settings file, then a size from the detected stack and the Mac's hardware.
public enum ResourcePlanner {
    public struct Host: Sendable {
        public var cores: Int
        public var memoryMB: Int

        public init(cores: Int, memoryMB: Int) {
            self.cores = cores
            self.memoryMB = memoryMB
        }

        public static var current: Host {
            Host(cores: ProcessInfo.processInfo.activeProcessorCount,
                 memoryMB: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576))
        }
    }

    /// Memory a typical compose service takes, for the warning only.
    static let serviceMemoryMB = 512

    public static func plan(explicit: ResourceLimits?, projectDefault: ResourceLimits?, config: (limits: ResourceLimits, source: String)?,
                            stack: ProjectStack?, services: Int, reservedMemoryMB: Int, host: Host = .current) -> ResourcePlan {
        var plan: ResourcePlan
        if let explicit {
            plan = ResourcePlan(limits: explicit, reason: "set for this task")
        } else if let projectDefault {
            plan = ResourcePlan(limits: projectDefault, reason: "project default")
        } else if let config {
            plan = ResourcePlan(limits: config.limits, reason: config.source)
        } else {
            plan = auto(stack: stack, host: host)
        }
        let total = reservedMemoryMB + plan.limits.memoryMB + services * serviceMemoryMB
        if total > host.memoryMB * 3 / 4 {
            plan.warning = "With the tasks already running, this would use \(gigabytes(total)) of your Mac’s \(gigabytes(host.memoryMB)) memory."
        }
        return plan
    }

    static func auto(stack: ProjectStack?, host: Host) -> ResourcePlan {
        let heavy = stack?.heavy == true
        let cpus = min(heavy ? 6 : 4, max(2, host.cores / 3))
        let wanted = heavy ? 8192 : 4096
        // Never more than half the Mac.
        let memory = max(2048, min(wanted, host.memoryMB / 2))
        let heavyName = stack?.ecosystems.first { [.rust, .java, .dotnet].contains($0) }?.displayName
        return ResourcePlan(limits: ResourceLimits(cpus: cpus, memoryMB: memory), reason: heavyName.map { "auto, \($0)" } ?? "auto")
    }

    /// "8 GB", "1.5 GB", "512 MB".
    public static func gigabytes(_ megabytes: Int) -> String {
        if megabytes < 1024 { return "\(megabytes) MB" }
        let gb = Double(megabytes) / 1024
        return gb == gb.rounded() ? "\(Int(gb)) GB" : String(format: "%.1f GB", gb)
    }
}

extension ResourceLimits {
    /// "4 CPU · 8 GB"
    public var summary: String { "\(cpus) CPU · \(ResourcePlanner.gigabytes(memoryMB))" }
}
