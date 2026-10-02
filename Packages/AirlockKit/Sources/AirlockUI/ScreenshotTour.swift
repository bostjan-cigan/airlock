import AirlockControl
import AirlockCore
import AppKit
import SwiftUI

/// `AIrlock --demo --screenshots <folder>`: walks the demo through its main screens and
/// captures each window with `screencapture` (which needs Screen Recording permission for
/// whatever launched the app), then quits.
///
/// - `<name>.png`: the window with its shadow.
/// - `frames/<name>/NNNN.png`: frames for a GIF, without the shadow. Make the GIF with
///   `Tools/make-gifs.sh <folder>`.
@MainActor
struct ScreenshotTour {
    let model: AppModel
    let folder: URL

    /// The folder after `--screenshots`, when one was given.
    static var folder: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--screenshots"), i + 1 < args.count, !args[i + 1].hasPrefix("-") else { return nil }
        return URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
    }

    func run() async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await pause(2)
        if mainWindow == nil {
            model.openWindow()
            await pause(2)
        }
        guard let window = mainWindow else {
            log("no main window")
            return NSApp.terminate(nil)
        }
        // A plain backdrop: the sidebar and inspector are translucent, so whatever is behind
        // the window would show through and change from frame to frame.
        let backdrop = Self.backdrop()
        backdrop?.orderFront(nil)
        window.setFrame(NSRect(x: 60, y: 60, width: 1440, height: 900), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        // Inspecting an untrusted repository: its report, and the New Task sheet set up for one.
        // `AIRLOCK_TOUR=inspection` stops after these.
        await show(.all, "Inspect event-stream-utils", tab: .report, inspector: .access)
        await save(window, "inspection-report")
        model.demoShowsNewTaskOptions = true
        model.isPresentingNewTask = true
        await pause(2)
        if let sheet = window.attachedSheet { await capture(sheet, to: folder.appending(path: "new-task-sheet.png"), shadow: true) }
        model.isPresentingNewTask = false
        model.demoShowsNewTaskOptions = false
        await pause(1)
        // A Claude chat asks to hand a task off: the review the user confirms.
        let review = HandoffReview(
            title: "Add rate limiting to the token endpoint", branch: "airlock/add-rate-limiting",
            commits: ["3f2a91c Add a token bucket per client", "8c01d4e Return 429 with Retry-After", "b7e5530 Test the limits"],
            files: 7, additions: 182, deletions: 40,
            attention: [.init(path: "package.json", reason: "install scripts and dependencies"), .init(path: ".github/workflows/ci.yml", reason: "runs in CI")],
            setup: "Nothing suspicious seen", setupFindings: 0, uncommitted: 0, nothingNew: false, plainFolder: false)
        let ask = Task { await model.requestApproval(ControlServer.handoffRequest(review)) }
        await pause(2)
        if let sheet = window.attachedSheet { await capture(sheet, to: folder.appending(path: "handoff.png"), shadow: true) }
        if let pending = model.approvals.first { model.answerApproval(pending.id, allowed: false) }
        _ = await ask.value
        await pause(1)

        // A sealed coding task: its setup report in the Access inspector.
        await show(.all, "Pen-test the OAuth endpoints", inspector: .access)
        await save(window, "sealed-access")
        if ProcessInfo.processInfo.environment["AIRLOCK_TOUR"] == "inspection" {
            backdrop?.close()
            log("saved to \(folder.path)")
            return NSApp.terminate(nil)
        }

        // Live: the agent's output arrives while you watch.
        await show(.active, "Pen-test the OAuth endpoints", settle: 0.8)
        await record(window, "live-terminal", seconds: 11)
        await save(window, "running")

        // A question waiting for you, then the sandbox holding and the hosts it refused.
        await show(.needsYou, "Refactor OAuth schema")
        await save(window, "needs-you")
        await show(.needsYou, "Try to break out of the sandbox", inspector: .access)
        await save(window, "blocked-hosts")

        // A finished task's diff, and a long-running one on an Apple VM.
        await show(.all, "Fix flaky checkout e2e test", tab: .changes, inspector: .info)
        await save(window, "changes")
        await show(.all, "Fuzz the query parser", inspector: .containers)
        await save(window, "apple-vm")

        // A project's own list.
        if let project = model.projects.first(where: { $0.name == "Auth & SSO" }) {
            await show(.project(project.id), "Pen-test the OAuth endpoints", inspector: .access)
            await save(window, "project")
        }

        // Going through the list, for a GIF.
        var frame = 0
        for title in ["Refactor OAuth schema", "Pen-test the OAuth endpoints", "Try to break out of the sandbox", "Fix flaky checkout e2e test", "Add idempotency keys to invoices"] {
            await show(.all, title, settle: 0.5)
            frame = await record(window, "tour", seconds: 2.2, from: frame)
        }

        await menuBar(besides: backdrop)
        backdrop?.close()
        log("saved to \(folder.path)")
        NSApp.terminate(nil)
    }

    private static func backdrop() -> NSWindow? {
        guard let screen = NSScreen.main else { return nil }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        return window
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "main" || ($0.title == "AIrlock" && $0.isVisible) }
    }

    private func log(_ text: String) {
        FileHandle.standardError.write(Data("screenshots: \(text)\n".utf8))
    }

    // MARK: Steps

    private func show(_ scope: SidebarScope, _ title: String?, tab: DetailTab = .terminal, inspector: InspectorTab = .containers, settle: Double = 2.5) async {
        UserDefaults.standard.set(true, forKey: "inspectorShown")
        UserDefaults.standard.set(inspector.rawValue, forKey: "inspectorTab")
        model.demoDetailTab = tab
        model.scope = scope
        model.selection = title.flatMap { title in model.tasks.values.first { $0.title == title }?.id }
        await pause(settle)
    }

    /// Opens the menu bar panel and saves it.
    private func menuBar(besides backdrop: NSWindow?) async {
        guard let button = NSApp.windows.lazy.compactMap({ $0.contentView.flatMap(Self.statusButton) }).first else {
            return log("no menu bar item")
        }
        button.performClick(nil)
        await pause(1.5)
        let panel = NSApp.windows.first {
            $0.isVisible && $0 !== mainWindow && $0 !== backdrop && $0.frame.height > 80 && !String(describing: type(of: $0)).contains("StatusBar")
        }
        if let panel { await save(panel, "menu-bar") } else { log("menu bar panel didn't open") }
        button.performClick(nil)
    }

    private static func statusButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews { if let found = statusButton(in: sub) { return found } }
        return nil
    }

    // MARK: Capture

    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    private func save(_ window: NSWindow, _ name: String) async {
        await capture(window, to: folder.appending(path: "\(name).png"), shadow: true)
    }

    /// Frames for `seconds`, numbered on from `from`; returns the next number.
    @discardableResult
    private func record(_ window: NSWindow, _ name: String, seconds: Double, from start: Int = 0) async -> Int {
        let dir = folder.appending(path: "frames/\(name)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let end = Date.now.addingTimeInterval(seconds)
        var frame = start
        while Date.now < end {
            let next = Date.now.addingTimeInterval(1 / 8)
            await capture(window, to: dir.appending(path: String(format: "%04d.png", frame)), shadow: false)
            frame += 1
            let wait = next.timeIntervalSinceNow
            if wait > 0 { await pause(wait) }
        }
        return frame
    }

    private func capture(_ window: NSWindow, to url: URL, shadow: Bool) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(window.windowNumber)] + (shadow ? [] : ["-o"]) + [url.path]
        do {
            try process.run()
            while process.isRunning { await pause(0.02) }
            if process.terminationStatus != 0 { log("screencapture failed for \(url.lastPathComponent)") }
        } catch {
            log("screencapture: \(error)")
        }
    }
}
