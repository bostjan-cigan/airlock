import AirlockCore
import AirlockEngine
import AppKit
import SwiftUI

/// What an inspection's code did once the network closed. Every name, path and line here
/// comes from inside the VM; it's shown as text, never acted on.
struct InspectionReportView: View {
    @Environment(AppModel.self) private var model
    let task: AgentTask
    @State private var confirmingDelete = false

    var body: some View {
        if let inspection = task.inspection {
            Form {
                Section {
                    LabeledContent("Repository") {
                        Text(inspection.source.label).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    }
                    LabeledContent("Runs in") { Text(task.runtime == .apple ? "Apple VM (its own kernel)" : "Docker container") }
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            if ![.finished, .failed, .investigating].contains(inspection.phase), task.lifecycle.isActive {
                                ProgressView().controlSize(.small)
                            }
                            Text(inspection.phase.title)
                        }
                    }
                } footer: {
                    if inspection.report == nil, inspection.phase != .failed {
                        Text("The network closes before any of the repository’s code runs. The report appears here when it’s done.")
                    }
                }
                if let report = inspection.report {
                    ReportSections(report: report, footnote: inspection.investigate ? "Claude’s findings are in the Terminal tab." : nil)
                }
            }
            .formStyle(.grouped)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    if let report = inspection.report {
                        Button("Copy report") { copy(report, inspection) }
                    }
                    Spacer()
                    Button("Delete VM…", role: .destructive) { confirmingDelete = true }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
            .confirmationDialog("Delete this inspection’s VM?", isPresented: $confirmingDelete) {
                Button("Delete VM", role: .destructive) { model.perform { _ = try await $0.remove(task.id) } }
            } message: {
                Text("The repository, its packages and everything they wrote are deleted. Nothing is kept.")
            }
        }
    }

    func copy(_ r: InspectionReport, _ inspection: Inspection) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("AIrlock inspection of \(inspection.source.label)\n" + ReportSections.text(r), forType: .string)
    }
}

/// What code did with the network closed: an inspection's report, or a sealed task's setup.
struct ReportSections: View {
    let report: InspectionReport
    var footnote: String?

    var body: some View {
        let r = report
        Section {
            Text(r.summary)
                .font(.headline)
                .foregroundStyle(r.findings > 0 ? .red : .primary)
        } footer: {
            Text("A clean report isn’t proof: code can wait, check whether it’s in a sandbox, or act only when it’s used."
                 + (footnote.map { " " + $0 } ?? ""))
        }
        Section("With the network closed") {
            finding("Hosts it looked up", r.triedHosts)
            finding("Connections it tried", r.triedAddresses)
            finding("Decoy credentials it read", r.credentialReads)
            finding("Files changed outside the repository", r.changedOutside)
            finding("Processes still running", r.processes)
        }
        Section("Its code") {
            list("Packages with install scripts", r.installScripts)
            list("Files changed in the repository", r.changedInRepo)
            LabeledContent("Ran") {
                Text(r.command.isEmpty ? "Nothing" : r.command)
                    .font(.callout.monospaced())
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            LabeledContent("Exit code") { Text(r.exitCode.map(String.init) ?? "–") }
            if !r.output.isEmpty {
                DisclosureGroup("Output") {
                    ScrollView {
                        Text(r.output)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 220)
                }
            }
        }
        Section {
            LabeledContent("Downloaded with scripts off") {
                Text(r.downloads.isEmpty ? "Nothing" : r.downloads.joined(separator: "\n"))
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(r.downloadFailed ? .orange : .secondary)
            }
        } footer: {
            if r.downloadFailed {
                Text("Some downloads failed, so some packages weren’t installed or run.")
            }
        }
    }

    /// A count that's red when anything was seen, with what it was.
    @ViewBuilder func finding(_ title: String, _ items: [String]) -> some View {
        if items.isEmpty {
            LabeledContent(title) { Text("None").foregroundStyle(.secondary) }
        } else {
            DisclosureGroup {
                ForEach(items, id: \.self) { item in
                    Text(item).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                }
            } label: {
                LabeledContent(title) { Text("\(items.count)").foregroundStyle(.red).fontWeight(.medium) }
            }
        }
    }

    /// The same, without alarm: these can be normal.
    @ViewBuilder func list(_ title: String, _ items: [String]) -> some View {
        if items.isEmpty {
            LabeledContent(title) { Text("None").foregroundStyle(.secondary) }
        } else {
            DisclosureGroup {
                ForEach(items, id: \.self) { item in
                    Text(item).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                }
            } label: {
                LabeledContent(title) { Text("\(items.count)") }
            }
        }
    }

    static func text(_ r: InspectionReport) -> String {
        func block(_ title: String, _ items: [String]) -> String {
            "\(title): " + (items.isEmpty ? "none" : "\n" + items.map { "  \($0)" }.joined(separator: "\n"))
        }
        return [
            r.summary,
            block("Hosts it looked up", r.triedHosts),
            block("Connections it tried", r.triedAddresses),
            block("Decoy credentials it read", r.credentialReads),
            block("Files changed outside the repository", r.changedOutside),
            block("Processes still running", r.processes),
            block("Packages with install scripts", r.installScripts),
            "Ran: \(r.command) (exit \(r.exitCode.map(String.init) ?? "?"))",
        ].joined(separator: "\n")
    }
}

/// A sealed task's setup report, from the Access inspector.
struct SetupReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: InspectionReport

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {} header: {
                    Text("Setup").font(.title2.weight(.semibold))
                } footer: {
                    Text("Dependencies downloaded with install scripts off, then the network closed and their install scripts ran. Decoy credentials are checked while the task runs.")
                }
                ReportSections(report: report)
            }
            .formStyle(.grouped)
            HStack {
                Button("Copy report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("AIrlock setup report\n" + ReportSections.text(report), forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 520, height: 620)
    }
}
