import SwiftUI
import UIKit
import Foundation
import Network
import Clerk
import ConvexMobile

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        return true
    }
}

struct RootViewWithStore: View {
    @StateObject private var store = AppStore()
    @Environment(\.clerk) private var clerk
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
                // Show AuthFlowView directly when not authenticated (matching original UX)
                AuthFlowView { session in
                    store.completeAuthentication(
                        id: session.account.id,
                        email: session.account.email,
                        name: session.account.displayName
                    )
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
        // Wait for Clerk to load
        // If user is already signed in via Clerk, complete authentication
        if let user = clerk.user {
            // Authenticate Convex first
            await Dependencies.authenticateConvex()
            
            let email = user.primaryEmailAddress?.emailAddress ?? ""
            let displayName = [user.firstName, user.lastName].compactMap { $0 }.joined(separator: " ")
            
            let accountService = Dependencies.current.accountService
            do {
                if let account = try await accountService.lookupAccount(byEmail: email) {
                    let session = UserSession(account: account)
                    store.completeAuthentication(
                        id: session.account.id,
                        email: session.account.email,
                        name: session.account.displayName
                    )
                } else {
                    let account = try await accountService.createAccount(email: email, displayName: displayName)
                    let session = UserSession(account: account)
                    store.completeAuthentication(
                        id: session.account.id,
                        email: session.account.email,
                        name: session.account.displayName
                    )
                }
                
                // Start real-time sync after successful authentication
                Dependencies.syncManager?.startSync()
                
            } catch {
                #if DEBUG
                print("[Auth] Failed to restore session: \(error.localizedDescription)")
                #endif
            }
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
    @State private var clerk = Clerk.shared
    
    let convexClient: ConvexClientWithAuth<ClerkAuthResult>

    init() {
        let authProvider = ClerkAuthProvider(jwtTemplate: "convex")
        convexClient = ConvexClientWithAuth(
            deploymentUrl: ConvexConfig.deploymentUrl,
            authProvider: authProvider
        )
        Dependencies.configure(client: convexClient)
        AppAppearance.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootViewWithStore()
                .environment(\.clerk, clerk)
                .task {
                    clerk.configure(publishableKey: "pk_test_YWNjdXJhdGUtZWFnbGUtODAuY2xlcmsuYWNjb3VudHMuZGV2JA")
                    try? await clerk.load()
                    
                    // Authenticate the Convex client after Clerk is ready
                    if clerk.user != nil {
                        await convexClient.loginFromCache()
                    }
                }
        }
    }
}

