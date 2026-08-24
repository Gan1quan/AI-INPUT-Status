import Foundation
import UIKit

final class AIInputStatusAppDelegate: NSObject, UIApplicationDelegate {
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        beginBackgroundExecution(application)
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        endBackgroundExecution(application)
    }

    private func beginBackgroundExecution(_ application: UIApplication) {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = application.beginBackgroundTask(withName: "AIInputStatusPolling") { [weak self, weak application] in
            guard let self, let application else { return }
            self.endBackgroundExecution(application)
        }
    }

    private func endBackgroundExecution(_ application: UIApplication) {
        guard backgroundTaskID != .invalid else { return }
        application.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
