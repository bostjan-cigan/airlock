import AirlockUI
import SwiftUI

struct AIrlockApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model: AppModel

    /// One model for the app's lifetime; the delegate reaches it here.
    @MainActor static var sharedModel: AppModel?

    init() {
        // `--demo` (or AIRLOCK_DEMO=1): sample tasks in every state, no containers or plugin.
        let demo = CommandLine.arguments.contains("--demo") || ProcessInfo.processInfo.environment["AIRLOCK_DEMO"] == "1"
        let model = demo ? AppModel.demo() : AppModel.live()
        _model = State(initialValue: model)
        Self.sharedModel = model
        // Start at launch so the menu bar, notifications and the plugin work
        // without the window ever opening.
        Task { await model.start() }
    }

    var body: some Scene {
        Window("AIrlock", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 560)
        }
        .defaultSize(width: 1200, height: 760)
        .commands { AboutCommands() }

        Window("About AIrlock", id: AboutView.windowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}
