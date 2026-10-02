import AirlockEngine
import AirlockRuntime
import AppKit
import SwiftTerm
import SwiftUI

/// Keeps one terminal per task alive across selection changes, so scrollback
/// and the connection survive switching between tasks.
@MainActor
final class TerminalRegistry {
    private var controllers: [UUID: TerminalController] = [:]

    func controller(for id: UUID, engine: TaskEngine) -> TerminalController {
        if let existing = controllers[id] { return existing }
        let controller = TerminalController(taskID: id, engine: engine)
        controllers[id] = controller
        return controller
    }

    func close(_ id: UUID) {
        controllers.removeValue(forKey: id)?.disconnect()
    }

    func closeAll() {
        for id in controllers.keys { close(id) }
    }
}

/// Bridges a SwiftTerm view to a container terminal session.
@MainActor
final class TerminalController: NSObject, TerminalViewDelegate {
    let taskID: UUID
    let engine: TaskEngine
    let view: TerminalView
    private(set) var isConnected = false
    private var session: (any TerminalSession)?
    private var readTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var input: AsyncStream<Data>.Continuation?
    private var scrollMonitor: Any?
    /// Trackpad scrolling not yet turned into whole lines.
    private var pendingScroll: CGFloat = 0

    init(taskID: UUID, engine: TaskEngine) {
        self.taskID = taskID
        self.engine = engine
        view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init()
        view.terminalDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = NSColor(calibratedRed: 0.106, green: 0.106, blue: 0.102, alpha: 1)
        view.nativeForegroundColor = NSColor(calibratedRed: 0.84, green: 0.83, blue: 0.80, alpha: 1)
        view.optionAsMetaKey = true
        // The agent's UI and tmux both ask for mouse events, which would turn every drag into
        // input for them. Keep clicks and drags in the view so dragging selects text (⌘C copies);
        // the scroll wheel is still forwarded, see `forwardScroll`.
        view.allowMouseReporting = false
    }

    /// Attaches to the task's agent session if not already attached.
    func connect() {
        guard !isConnected else { return }
        isConnected = true
        let terminal = view.getTerminal()
        let size = TerminalSize(cols: max(terminal.cols, 20), rows: max(terminal.rows, 5))
        Task {
            do {
                let session = try await engine.openTerminal(taskID, size: size)
                attach(session)
            } catch {
                view.feed(text: "\r\n\u{1B}[2m[airlock] couldn't attach: \(error)\u{1B}[0m\r\n")
                isConnected = false
            }
        }
    }

    private func attach(_ session: any TerminalSession) {
        self.session = session
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.forwardScroll(event) == true } ? nil : event
        }
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        input = continuation
        // One writer keeps keystrokes in order.
        writeTask = Task {
            for await data in stream { try? await session.write(data) }
        }
        readTask = Task { [weak self] in
            for await data in session.output {
                self?.view.feed(byteArray: ArraySlice(data))
            }
            self?.detached()
        }
    }

    private func detached() {
        view.feed(text: "\r\n\u{1B}[2m[airlock] detached\u{1B}[0m\r\n")
        disconnect()
    }

    func disconnect() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        pendingScroll = 0
        input?.finish()
        input = nil
        readTask?.cancel()
        writeTask?.cancel()
        if let session { Task { await session.close() } }
        session = nil
        isConnected = false
    }

    /// The agent runs inside tmux, which draws on the alternate screen, so the view itself has
    /// no scrollback; history lives in tmux, or in the agent's own full-screen UI. SwiftTerm's
    /// `scrollWheel` only scrolls the view (and can't be overridden), so wheel events over the
    /// view are sent on as mouse wheel events whenever the program in the terminal asked for
    /// mouse events. tmux hands them to the agent's UI when it wants them, and otherwise scrolls
    /// its history in copy mode, one line per event (see tmux.conf). Returns whether it was handled.
    private func forwardScroll(_ event: NSEvent) -> Bool {
        guard let window = view.window, event.window === window, !view.isHiddenOrHasHiddenAncestor,
              event.scrollingDeltaY != 0 else { return false }
        let point = view.convert(event.locationInWindow, from: nil)
        let terminal = view.getTerminal()
        guard view.bounds.contains(point), terminal.mouseMode != .off else { return false }

        let cellHeight = view.bounds.height / CGFloat(max(terminal.rows, 1))
        let cellWidth = view.bounds.width / CGFloat(max(terminal.cols, 1))
        var lines: Int
        if event.hasPreciseScrollingDeltas {
            // Trackpads: about one line per line-height of finger movement.
            pendingScroll += event.scrollingDeltaY
            lines = Int(pendingScroll / cellHeight)
            pendingScroll -= CGFloat(lines) * cellHeight
        } else {
            // Mouse wheels: three lines per notch, more when the wheel accelerates.
            lines = Int(event.scrollingDeltaY.rounded())
            if lines == 0 { lines = event.scrollingDeltaY > 0 ? 1 : -1 }
            lines *= 3
        }
        guard lines != 0 else { return true }
        let col = min(max(Int(point.x / cellWidth), 0), terminal.cols - 1)
        let row = min(max(Int((view.bounds.height - point.y) / cellHeight), 0), terminal.rows - 1)
        // Positive deltas reveal earlier output: wheel up (button 4).
        let flags = terminal.encodeButton(button: lines > 0 ? 4 : 5, release: false, shift: false, meta: false, control: false)
        for _ in 0..<abs(lines) { terminal.sendEvent(buttonFlags: flags, x: col, y: row) }
        return true
    }

    // MARK: TerminalViewDelegate

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        MainActor.assumeIsolated { _ = input?.yield(bytes) }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            guard let session else { return }
            Task { try? await session.resize(TerminalSize(cols: newCols, rows: newRows)) }
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func bell(source: TerminalView) { NSSound.beep() }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        MainActor.assumeIsolated {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}

/// Hosts a task's persistent terminal view inside SwiftUI.
struct TerminalHostView: NSViewRepresentable {
    let controller: TerminalController
    let isRunning: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let view = controller.view
        if view.superview !== container {
            view.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        if isRunning {
            // Let layout settle so the session opens at the real size.
            DispatchQueue.main.async {
                controller.connect()
                view.window?.makeFirstResponder(view)
            }
        }
    }
}
