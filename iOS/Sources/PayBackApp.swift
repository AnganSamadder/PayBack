import SwiftUI
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        return true
    }
}

struct RootViewWithStore: View {
    @StateObject private var store = AppStore()

    var body: some View {
        RootView()
            .environmentObject(store)
    }
}



@main
struct PayBackApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        AppAppearance.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootViewWithStore()
        }
    }
}