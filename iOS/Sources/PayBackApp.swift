import SwiftUI
import UIKit

@main
struct PayBackApp: App {
    @StateObject private var store = AppStore()
    init() {
        AppAppearance.configure()
    }
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}


