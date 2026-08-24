import BackgroundTasks
import Foundation
import UIKit

let aiInputBackgroundRefreshIdentifier = "com.gan1quan.aiinputstatus.refresh"

func registerAIInputBackgroundRefresh() {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: aiInputBackgroundRefreshIdentifier, using: nil) { task in
        scheduleAIInputBackgroundRefresh()
        let refreshTask = Task {
            await StatusStore.performBackgroundRefresh()
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = {
            refreshTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}

func scheduleAIInputBackgroundRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: aiInputBackgroundRefreshIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 30)
    try? BGTaskScheduler.shared.submit(request)
}

final class AIInputStatusAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        registerAIInputBackgroundRefresh()
        scheduleAIInputBackgroundRefresh()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleAIInputBackgroundRefresh()
    }
}
