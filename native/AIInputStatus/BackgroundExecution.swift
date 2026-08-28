import BackgroundTasks
import Foundation
import UIKit

private let backgroundRefreshTaskIdentifier = "com.gan1quan.aiinputstatus.refresh"

final class AIInputStatusAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundExecution.register()
        BackgroundExecution.schedule()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        BackgroundExecution.schedule()
    }
}

enum BackgroundExecution {
    private static let interval: TimeInterval = 15 * 60
    private static var registered = false

    static func register() {
        guard !registered else { return }
        registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundRefreshTaskIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task)
        }
    }

    static func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundRefreshTaskIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: backgroundRefreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        var work: Task<Void, Never>?
        task.expirationHandler = { work?.cancel() }
        work = Task {
            let success = await refreshStatus()
            guard !Task.isCancelled else {
                task.setTaskCompleted(success: false)
                return
            }
            task.setTaskCompleted(success: success)
        }
    }

    private static func refreshStatus() async -> Bool {
        do {
            let result = try await StatusNetwork.loadStatus(daemonTimeout: 1)
            let settings = StatusEngine.loadNotificationSettings()
            let changes = StatusEngine.updateEvents(result.snapshot, settings: settings)
            guard settings.enabled else { return true }
            if !changes.opened.isEmpty { await NotificationEngine.notifyStatusOpened(changes.opened) }
            if settings.recoveryEnabled && !changes.recovered.isEmpty {
                await NotificationEngine.notifyStatusRecovered(changes.recovered)
            }
            return true
        } catch {
            return false
        }
    }
}
