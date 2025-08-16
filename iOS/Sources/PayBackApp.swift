import SwiftUI

@main
struct PayBackApp: App {
    @StateObject private var store = AppStore()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}


