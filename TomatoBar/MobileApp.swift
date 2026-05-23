import SwiftUI
import UIKit

final class TBMobileAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        TBCloudKitSyncStore.shared.handleRemoteNotification(userInfo: userInfo)
        completionHandler(.newData)
    }
}

@main
struct TBMobileApp: App {
    @UIApplicationDelegateAdaptor(TBMobileAppDelegate.self) private var appDelegate
    @StateObject private var timer = TBSharedTimerController()

    init() {
        TBCloudKitSyncStore.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            TBSharedTimerView(timer: timer)
        }
    }
}
