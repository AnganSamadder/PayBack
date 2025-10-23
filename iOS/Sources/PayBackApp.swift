import SwiftUI
import UIKit
import FirebaseCore
import FirebaseAuth

enum FirebaseConfigurator {
    static func configureIfNeeded() {
        guard FirebaseApp.app() == nil else { return }

        let options: FirebaseOptions?
        if let plistPath = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") {
            options = FirebaseOptions(contentsOfFile: plistPath)
        } else {
            options = FirebaseOptions.defaultOptions()
        }

        guard let resolvedOptions = options else {
            #if DEBUG
            print("[Firebase] GoogleService-Info.plist is missing or invalid – authentication flow will be disabled.")
            #endif
            return
        }

        FirebaseApp.configure(options: resolvedOptions)

        guard let app = FirebaseApp.app() else {
            #if DEBUG
            print("[Firebase] Configuration still missing – check GoogleService-Info.plist bundle settings.")
            #endif
            return
        }

        #if DEBUG
        #if targetEnvironment(simulator)
        Auth.auth().settings?.isAppVerificationDisabledForTesting = true
        #endif
        print("[Firebase] Configured: \(app.name) (AppID: \(app.options.googleAppID))")
        #endif
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Auth.auth().setAPNSToken(deviceToken, type: .prod)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        #if DEBUG
        print("[Push] Failed to register for remote notifications: \(error.localizedDescription)")
        #endif
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any]) {
        if Auth.auth().canHandleNotification(userInfo) {
            return
        }
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        FirebaseConfigurator.configureIfNeeded()
        UIApplication.shared.registerForRemoteNotifications()
        return true
    }
}

struct RootViewWithStore: View {
    @StateObject private var store = AppStore()

    var body: some View {
        Group {
            if store.session != nil {
                RootView()
            } else {
                AuthFlowView { session in
                    store.completeAuthentication(with: session)
                }
            }
        }
        .environmentObject(store)
        .animation(.easeInOut(duration: 0.25), value: store.session != nil)
    }
}



@main
struct PayBackApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        FirebaseConfigurator.configureIfNeeded()
        AppAppearance.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootViewWithStore()
        }
    }
}
