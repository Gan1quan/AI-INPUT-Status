import BackgroundTasks
import UIKit

final class AIInputStatusAppDelegate: NSObject, UIApplicationDelegate {
    static let refreshIdentifier = "com.gan1quan.aiinputstatus.refresh"

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        registerBackgroundRefresh()
        Self.scheduleBackgroundRefresh()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Self.scheduleBackgroundRefresh()
    }

    private func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshIdentifier, using: nil) { task in
            self.handleBackgroundRefresh(task: task)
        }
    }

    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        // iOS chooses the actual execution time; this is a lower bound, not a timer.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // The app can still be refreshed when foregrounded or by the DEB daemon.
        }
    }

    private func handleBackgroundRefresh(task: BGTask) {
        Self.scheduleBackgroundRefresh()
        let worker = Task { @MainActor in
            let store = StatusStore(autoRefresh: false)
            await store.refresh(source: "后台刷新", forceSubscription: true)
            task.setTaskCompleted(success: store.snapshot != nil)
        }
        task.expirationHandler = { worker.cancel() }
    }
}
