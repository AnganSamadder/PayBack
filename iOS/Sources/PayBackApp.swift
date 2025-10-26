import SwiftUI
import UIKit
import FirebaseCore
import FirebaseAuth
import Network

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
            print("[Firebase] GoogleService-Info.plist is missing or invalid - authentication flow will be disabled.")
            #endif
            return
        }

        FirebaseApp.configure(options: resolvedOptions)

        guard let app = FirebaseApp.app() else {
            #if DEBUG
            print("[Firebase] Configuration still missing - check GoogleService-Info.plist bundle settings.")
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
    @State private var isCheckingAuth = true
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var networkMonitor = NetworkMonitor()
    @State private var pendingInviteToken: UUID?

    var body: some View {
        Group {
            if isCheckingAuth {
                // Show loading state while checking for existing session
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.22, blue: 0.56),
                            Color(red: 0.41, green: 0.13, blue: 0.6),
                            Color(red: 0.06, green: 0.55, blue: 0.7)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()
                    
                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(1.2)
                        Text("PayBack")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
            } else if store.session != nil {
                RootView(pendingInviteToken: $pendingInviteToken)
            } else {
                AuthFlowView { session in
                    store.completeAuthentication(with: session)
                }
            }
        }
        .environmentObject(store)
        .animation(.easeInOut(duration: 0.25), value: store.session != nil)
        .task {
            await checkExistingSession()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(oldPhase: oldPhase, newPhase: newPhase)
        }
        .onChange(of: networkMonitor.isConnected) { wasConnected, isConnected in
            handleNetworkChange(wasConnected: wasConnected, isConnected: isConnected)
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
    }
    
    private func checkExistingSession() async {
        // Check if user is already logged in with Firebase
        guard let firebaseUser = Auth.auth().currentUser else {
            isCheckingAuth = false
            return
        }
        
        #if DEBUG
        print("[Auth] Found existing Firebase session for user: \(firebaseUser.uid)")
        #endif
        
        // Try to restore the user's account
        let accountService = AccountServiceProvider.makeAccountService()
        
        do {
            // Look up account by email if available
            if let email = firebaseUser.email {
                if let account = try await accountService.lookupAccount(byEmail: email) {
                    let session = UserSession(account: account)
                    store.completeAuthentication(with: session)
                    isCheckingAuth = false
                    return
                }
            }
            
            // If no account found, create one with available info
            let displayName = firebaseUser.displayName ?? firebaseUser.email?.split(separator: "@").first.map(String.init) ?? "User"
            let email = firebaseUser.email ?? "\(firebaseUser.uid)@payback.local"
            
            let account = try await accountService.createAccount(email: email, displayName: displayName)
            let session = UserSession(account: account)
            store.completeAuthentication(with: session)
            
        } catch {
            #if DEBUG
            print("[Auth] Failed to restore session: \(error.localizedDescription)")
            #endif
            // Sign out on error to force fresh login
            try? Auth.auth().signOut()
        }
        
        isCheckingAuth = false
    }
    
    private func handleScenePhaseChange(oldPhase: ScenePhase, newPhase: ScenePhase) {
        // Trigger reconciliation when app becomes active
        if oldPhase != .active && newPhase == .active {
            #if DEBUG
            print("[App] App became active - triggering link state reconciliation")
            #endif
            
            Task {
                await store.reconcileAfterNetworkRecovery()
            }
        }
    }
    
    private func handleNetworkChange(wasConnected: Bool, isConnected: Bool) {
        // Trigger reconciliation when network is restored
        if !wasConnected && isConnected {
            #if DEBUG
            print("[App] Network connection restored - triggering link state reconciliation")
            #endif
            
            Task {
                await store.reconcileAfterNetworkRecovery()
            }
        }
    }
    
    private func handleDeepLink(_ url: URL) {
        #if DEBUG
        print("[DeepLink] Received URL: \(url.absoluteString)")
        #endif
        
        // Parse the URL: payback://link/claim?token=<uuid>
        guard url.scheme == "payback" else {
            #if DEBUG
            print("[DeepLink] Invalid scheme: \(url.scheme ?? "nil")")
            #endif
            return
        }
        
        guard url.host == "link" else {
            #if DEBUG
            print("[DeepLink] Invalid host: \(url.host ?? "nil")")
            #endif
            return
        }
        
        guard url.path == "/claim" else {
            #if DEBUG
            print("[DeepLink] Invalid path: \(url.path)")
            #endif
            return
        }
        
        // Extract token parameter
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let tokenString = queryItems.first(where: { $0.name == "token" })?.value,
              let tokenId = UUID(uuidString: tokenString) else {
            #if DEBUG
            print("[DeepLink] Failed to extract token from URL")
            #endif
            return
        }
        
        #if DEBUG
        print("[DeepLink] Extracted token: \(tokenId)")
        #endif
        
        // Store the token to be handled by RootView
        pendingInviteToken = tokenId
    }
}

/// Monitors network connectivity status
class NetworkMonitor: ObservableObject {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    
    @Published var isConnected: Bool = true
    @Published var connectionType: NWInterface.InterfaceType?
    
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
                self?.connectionType = path.availableInterfaces.first?.type
                
                #if DEBUG
                if path.status == .satisfied {
                    print("[Network] Connection available: \(path.availableInterfaces.first?.type.debugDescription ?? "unknown")")
                } else {
                    print("[Network] Connection unavailable")
                }
                #endif
            }
        }
        monitor.start(queue: queue)
    }
    
    deinit {
        monitor.cancel()
    }
}

extension NWInterface.InterfaceType {
    var debugDescription: String {
        switch self {
        case .wifi: return "WiFi"
        case .cellular: return "Cellular"
        case .wiredEthernet: return "Ethernet"
        case .loopback: return "Loopback"
        case .other: return "Other"
        @unknown default: return "Unknown"
        }
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
