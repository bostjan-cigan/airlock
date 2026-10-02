import AirlockApple
import AirlockCore
import AirlockEngine
import AirlockProviders
import AirlockRuntime
import SwiftUI

public struct SettingsView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        TabView {
            AccountsSettings()
                .tabItem { Label("Accounts", systemImage: "key") }
            RuntimeSettings()
                .tabItem { Label("Runtimes", systemImage: "shippingbox") }
            StorageSettings()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .frame(width: 520)
        .padding(.vertical, 8)
    }
}

struct AccountsSettings: View {
    @Environment(AppModel.self) private var model
    /// Bumped when a secret changes, so the "Using…" line re-reads the Keychain.
    @State private var revision = 0

    var body: some View {
        Form {
            Section {
                SecretField(key: .claudeOAuthToken, label: "Claude token", placeholder: "sk-ant-oat01-…") { revision += 1 }
                SecretField(key: .anthropicAPIKey, label: "Anthropic API key", placeholder: "sk-ant-api03-…") { revision += 1 }
                ActiveCredential(revision: revision)
            } header: {
                Text("Claude Code")
            } footer: {
                Text("Run `claude setup-token` in your terminal to create a long-lived token for your Claude subscription, or use an API key. Either is enough; the token wins when both are set. Secrets stay in your Keychain and are only passed to the agent process, never stored in the container.")
                    .foregroundStyle(.secondary)
            }
            Section {
                SecretField(key: .githubToken, label: "GitHub token", placeholder: "github_pat_…")
            } header: {
                Text("GitHub")
            } footer: {
                Text("Optional, and only given to tasks you start with GitHub access turned on. Agents normally commit locally and you push after reviewing. Prefer a fine-grained token limited to the repositories you work on.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Which credential the next task will use.
struct ActiveCredential: View {
    @Environment(AppModel.self) private var model
    let revision: Int

    var body: some View {
        let has = { (key: SecretKey) in ((try? model.secrets.get(key)) ?? nil)?.isEmpty == false }
        let _ = revision
        if has(.claudeOAuthToken) {
            Label("Tasks use your Claude token", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if has(.anthropicAPIKey) {
            Label("Tasks use your API key, billed per use", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Label("Add a token or API key to start tasks", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}

struct SecretField: View {
    @Environment(AppModel.self) private var model
    let key: SecretKey
    let label: String
    let placeholder: String
    var onChange: () -> Void = {}
    @State private var value = ""
    @State private var saved = false

    var body: some View {
        LabeledContent(label) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    SecureField(label, text: $value, prompt: Text(saved ? "Saved in Keychain" : placeholder))
                        .labelsHidden()
                        .onSubmit(save)
                    if !value.isEmpty {
                        Button("Save", action: save)
                    } else if saved {
                        Button("Remove", role: .destructive) {
                            try? model.secrets.set(nil, for: key)
                            saved = false
                            onChange()
                        }
                    }
                }
                if !value.isEmpty, let prefix = key.expectedPrefix, !key.looksValid(key.sanitize(value)) {
                    Text("This doesn't look like a \(label.lowercased()); those start with \(prefix).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .onAppear { saved = ((try? model.secrets.get(key)) ?? nil) != nil }
    }

    func save() {
        let clean = key.sanitize(value)
        guard !clean.isEmpty else { return }
        do {
            try model.secrets.set(clean, for: key)
            value = ""
            saved = true
            onChange()
        } catch {
            model.errorMessage = String(describing: error)
        }
    }
}

struct RuntimeSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(RuntimeKind.defaultsKey) private var defaultRuntime: RuntimeKind = .docker

    var body: some View {
        Form {
            Section {
                Picker("New tasks run on", selection: $defaultRuntime) {
                    ForEach(RuntimeKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                if case .unavailable(let reason)? = model.runtimeStatus[defaultRuntime] {
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } footer: {
                Text("Used by the New Task sheet and by tasks handed off from Claude that don't ask for a runtime.")
                    .foregroundStyle(.secondary)
            }
            ForEach(RuntimeKind.allCases, id: \.self) { kind in
                Section(kind.displayName) {
                    switch model.runtimeStatus[kind] {
                    case .available(let version)?:
                        Label("Ready (\(version))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .unavailable(let reason)?:
                        Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    case nil:
                        ProgressView().controlSize(.small)
                    }
                    if kind == .apple {
                        AppleKernelRow()
                    }
                }
            }
            Button("Check again") { Task { await model.refreshRuntimes() } }
        }
        .formStyle(.grouped)
    }
}

struct AppleKernelRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let progress = model.kernelDownload {
            ProgressView(value: progress) {
                Text("Downloading the Linux kernel…")
            }
        } else if !model.appleAssets.hasKernel {
            LabeledContent {
                Button("Download") { Task { await model.installAppleKernel() } }
            } label: {
                Text("Linux kernel")
                Text("Kata Containers 3.32 kernel, \(AppleRuntimeAssets.kernelDownloadSize). Checked against its published checksum.")
            }
        } else {
            LabeledContent("Linux kernel", value: "Installed")
        }
        Text("Each Apple VM task runs in its own lightweight virtual machine. VMs stop when AIrlock quits; start the task again to resume.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

/// What AIrlock keeps on disk, and how it tidies up.
struct StorageSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.autoCleanKey) private var autoClean = true
    @AppStorage(AgentVersions.shareUserSetupKey) private var shareSetup = true
    @State private var usage: StorageUsage?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                row("Task checkouts", usage?.workspaces)
                row("Package caches", usage?.caches)
                row("Images", usage?.images)
                row("Clones and service data", usage?.volumes)
                LabeledContent("Total") { Text(usage.map { bytes($0.total) } ?? "…").fontWeight(.medium) }
            } header: {
                Text("Disk used by AIrlock")
            } footer: {
                HStack {
                    Text(message ?? "Caches make the next task's installs fast; clearing them is safe.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Caches") {
                        Task {
                            do {
                                try await model.engine.clearCaches()
                                message = "Caches cleared"
                            } catch {
                                message = String(describing: error)
                            }
                            usage = await model.engine.storageUsage()
                        }
                    }
                }
            }
            Section {
                Toggle("Remove finished tasks after 7 days", isOn: $autoClean)
                Toggle("Give agents my Claude instructions and skills", isOn: $shareSetup)
            } footer: {
                Text("Removing a task keeps its branch in your repository. Agents get ~/.claude/CLAUDE.md and ~/.claude/skills; your MCP servers stay on this Mac.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { usage = await model.engine.storageUsage() }
    }

    func row(_ label: String, _ value: Int64?) -> some View {
        LabeledContent(label) { Text(value.map(bytes) ?? "…").monospacedDigit() }
    }

    func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
