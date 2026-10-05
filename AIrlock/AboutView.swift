import SwiftUI

struct AboutView: View {
    static let windowID = "about"
    static let homepage = URL(string: "https://bostjan-cigan.com")!
    static let license = URL(string: "https://github.com/bostjan-cigan/airlock/blob/main/LICENSE")!
    static let source = URL(string: "https://github.com/bostjan-cigan/airlock")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    /// `NSHumanReadableCopyright` from the build settings.
    private var copyright: String? {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 2) {
                Text("AIrlock").font(.title.bold())
                Text(version).font(.callout).foregroundStyle(.secondary)
            }
            Text("Created with passion on a \(Image(systemName: "cloud.rain")) day by Boštjan Cigan.")
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Link(destination: Self.homepage) {
                    Label("Homepage", systemImage: "globe")
                }
                .help(Self.homepage.absoluteString)
                Link(destination: Self.source) {
                    Label("Source", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .help(Self.source.absoluteString)
                Link(destination: Self.license) {
                    Label("License", systemImage: "doc.text")
                }
                .help(Self.license.absoluteString)
            }
            if let copyright, !copyright.isEmpty {
                Text(copyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(width: 380)
    }
}

/// Replaces the standard About panel with `AboutView`.
struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About AIrlock") {
                NSApp.activate()
                openWindow(id: AboutView.windowID)
            }
        }
    }
}
