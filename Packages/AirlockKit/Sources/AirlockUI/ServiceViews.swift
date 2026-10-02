import AirlockCore
import AppKit
import SwiftUI

extension ServiceInstance.State {
    var color: Color {
        switch self {
        case .healthy, .running: .green
        case .pending, .pulling, .starting: .yellow
        case .stopped: .secondary
        case .failed: .red
        }
    }
}

struct LogsSheet: View {
    let title: String
    let text: String
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "No output." : text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .id("end")
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .frame(width: 720, height: 460)
    }
}

struct AddPortPopover: View {
    @Environment(AppModel.self) private var model
    let task: AgentTask
    let done: () -> Void
    @State private var text = ""
    @State private var suggestions: [Int] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Forward a port to localhost").font(.headline)
            HStack {
                TextField("3000", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onSubmit { expose(Int(text)) }
                Button("Forward") { expose(Int(text)) }
                    .disabled(Int(text) == nil)
            }
            if !suggestions.isEmpty {
                Text("Listening or declared").font(.caption).foregroundStyle(.secondary)
                HStack {
                    ForEach(suggestions.prefix(6), id: \.self) { port in
                        Button("\(port)") { expose(port) }
                    }
                }
            }
        }
        .padding(14)
        .task {
            let declared = (task.services?.items ?? []).flatMap(\.ports)
            let listening = await model.engine.listeningPorts(task.id)
            let taken = Set(task.ports.map(\.containerPort))
            suggestions = Array(Set(declared + listening).subtracting(taken)).sorted()
        }
    }

    func expose(_ port: Int?) {
        guard let port else { return }
        model.perform { try await $0.expose(task.id, port: port) }
        done()
    }
}

/// "+3" next to a task's title: containers running next to the agent.
