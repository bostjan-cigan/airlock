import AirlockUI
import AppKit
import UserNotifications

/// Routes notification clicks to the task they're about.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var model: AppModel? { AIrlockApp.sharedModel }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Apple VMs run inside this process: confirm, then stop them cleanly.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Demo tasks are pretend, so quitting stops nothing.
        guard let model, !model.isDemo, !model.tasksEndingWithApp.isEmpty else { return .terminateNow }
        let count = model.tasksEndingWithApp.count
        let alert = NSAlert()
        alert.messageText = "Stop \(count) Apple VM task\(count == 1 ? "" : "s")?"
        alert.informativeText = "Apple VMs run inside AIrlock, so quitting stops them. Their files are kept, and starting a task again resumes its agent conversation. Docker tasks keep running."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task {
            await model.prepareForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let raw = response.notification.request.content.userInfo["task"] as? String
        let approval = response.notification.request.content.userInfo["approval"] != nil
        let action = response.actionIdentifier
        let blocked = response.notification.request.content.categoryIdentifier == AppModel.blockedCategory
        completionHandler()
        if approval {
            // The Allow / Don't Allow prompt is in the window.
            Task { @MainActor in
                self.model?.openWindow()
                NSApp.activate()
            }
            return
        }
        guard let id = raw.flatMap(UUID.init(uuidString:)) else { return }
        Task { @MainActor in
            guard let model = self.model else { return }
            if action == AppModel.allowAction {
                // Allowed from the notification: no need to bring the app forward.
                await model.allowAllBlocked(id)
                return
            }
            model.reveal(id)
            if blocked, model.tasks[id]?.blockedHosts.isEmpty == false { model.blockedReview = TaskRef(id) }
            NSApp.activate()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
