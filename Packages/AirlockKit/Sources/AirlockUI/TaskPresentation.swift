import AirlockCore
import SwiftUI

/// Colors, labels and small views shared by the sidebar, list, detail and menu bar.
extension AgentTask {
    /// The status dot in the task header: green while running, blue when it waits for you,
    /// red for failures, yellow while starting, gray otherwise.
    var statusColor: Color {
        switch status {
        case .failed: .red
        case .needsInput: .blue
        case .working: .green
        case .starting: .yellow
        case .ready, .exited, .stopped, .done: .gray
        }
    }

    /// "Open network, GitHub, API key": what this task may do beyond the default sandbox.
    var elevatedSummary: String? {
        let names = permissions.filter(\.isElevated).map { permission -> String in
            switch permission.kind {
            case .network: "Open network"
            case .github: "GitHub"
            case .credential: "API key"
            case .files: "Files on your Mac"
            default: permission.title
            }
        }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }
}


struct TagChip: View {
    let tag: String
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 3) {
            Text(tag)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Remove tag")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.5), in: .capsule)
        .overlay(Capsule().strokeBorder(.quaternary))
        .foregroundStyle(.primary)
    }
}

