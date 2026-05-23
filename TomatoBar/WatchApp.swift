import SwiftUI
import WatchKit

final class TBWatchAppDelegate: NSObject, WKExtensionDelegate {
    func applicationDidFinishLaunching() {
        WKExtension.shared().registerForRemoteNotifications()
    }

    func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any],
                                      fetchCompletionHandler completionHandler: @escaping (WKBackgroundFetchResult) -> Void) {
        TBCloudKitSyncStore.shared.handleRemoteNotification(userInfo: userInfo)
        completionHandler(.newData)
    }
}

@main
struct TBWatchApp: App {
    @WKExtensionDelegateAdaptor(TBWatchAppDelegate.self) private var appDelegate
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
