import SwiftUI
import UIKit

@main
struct AIInputStatusApp: App {
    @UIApplicationDelegateAdaptor(AIInputStatusAppDelegate.self) private var appDelegate
    @StateObject private var store = StatusStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(nil)
        }
    }
}
