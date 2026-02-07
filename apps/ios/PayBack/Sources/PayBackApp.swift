import SwiftUI
import UIKit
import Foundation
import Network
import Clerk

#if !PAYBACK_CI_NO_CONVEX
import ConvexMobile
#endif

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        AppConfig.markTiming("AppDelegate.didFinishLaunching")
        return true
    }
}

struct RootViewWithStore: View {
    @StateObject private var store: AppStore
    @Environment(\.clerk) private var clerk
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var networkMonitor = NetworkMonitor()
    @State private var pendingInviteToken: UUID?

    init() {
        AppConfig.markTiming("RootViewWithStore init started")
        // Initialize StateObject manually to track timing
        let storeInstance = AppStore()
        _store = StateObject(wrappedValue: storeInstance)
        AppConfig.markTiming("RootViewWithStore init completed")
        
        AppConfig.markTiming("NetworkMonitor init started")
        _networkMonitor = StateObject(wrappedValue: NetworkMonitor())
        AppConfig.markTiming("NetworkMonitor init completed")
    }

    var body: some View {
        Group {
            // Use store's state instead of local state to avoid view lifecycle delays
            if store.isCheckingAuth {
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
                    .onAppear {
                         AppConfig.markTiming("Loading Screen appeared")
                    }
                }
            } else if store.session != nil {
                RootView(pendingInviteToken: $pendingInviteToken)
                    .onAppear {
                         AppConfig.markTiming("RootView appeared")
                    }
            } else {
                // Show AuthFlowView directly when not authenticated (matching original UX)
                // Show AuthFlowView directly when not authenticated (matching original UX)
                AuthFlowView(store: store) { session in
                    // Session setup is handled internally by AppStore.login/signup
                    #if DEBUG
                    print("Auth flow completed for: \(session.account.email)")
                    #endif
                }
                .onAppear {
                     AppConfig.markTiming("AuthFlowView appeared")
                }
            }
        }
        .environmentObject(store)
        .animation(.easeInOut(duration: 0.25), value: store.session != nil)
        .task {
            AppConfig.markTiming("RootViewWithStore.task triggered (Auth check already running in AppStore)")
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
        .alert(item: $store.logoutAlert) { alert in
            switch alert {
            case .accountDeleted:
                return Alert(
                    title: Text("Account Deleted"),
                    message: Text("Your account has been deleted. If this was a mistake, please contact support."),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }
    
    private func handleScenePhaseChange(oldPhase: ScenePhase, newPhase: ScenePhase) {
        AppConfig.markTiming("ScenePhase changed: \(oldPhase) -> \(newPhase)")
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
        AppConfig.markTiming("NetworkMonitor init started")
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
                self?.connectionType = path.availableInterfaces.first?.type
                
                #if DEBUG
                if path.status == .satisfied && AppConfig.verboseLogging {
                    print("[Network] Connection available: \(path.availableInterfaces.first?.type.debugDescription ?? "unknown")")
                } else if AppConfig.verboseLogging {
                    print("[Network] Connection unavailable")
                }
                #endif
            }
        }
        monitor.start(queue: queue)
        AppConfig.markTiming("NetworkMonitor init completed")
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
    @State private var clerk = Clerk.shared
    
    #if !PAYBACK_CI_NO_CONVEX
    let convexClient: ConvexClientWithAuth<ClerkAuthResult>
    #endif

    init() {
        // Start performance tracking
        AppConfig.markAppStart()
        
        // Log startup configuration
        AppConfig.logStartupInfo()
        AppConfig.markTiming("Configuration logged")
        
        #if !PAYBACK_CI_NO_CONVEX
        let authProvider = ClerkAuthProvider(jwtTemplate: "convex")
        AppConfig.markTiming("ClerkAuthProvider created")

        convexClient = ConvexClientWithAuth(
            deploymentUrl: ConvexConfig.deploymentUrl,
            authProvider: authProvider
        )
        AppConfig.markTiming("ConvexClient created")

        Dependencies.configure(client: convexClient)
        AppConfig.markTiming("Dependencies configured")
        #else
        AppConfig.markTiming("Convex disabled for CI")
        #endif
        
        AppAppearance.configure()
        AppConfig.markTiming("Appearance configured")
        
        AppConfig.log("PayBack initialization complete")
    }

    var body: some Scene {
        WindowGroup {
            RootViewWithStore()
                .environment(\.clerk, clerk)
        }
    }
}
