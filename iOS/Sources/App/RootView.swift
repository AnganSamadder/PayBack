import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            GroupsListView()
                .tabItem { Label("Groups", systemImage: "person.3") }

            Text("Activity")
                .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
        }
        .tint(AppTheme.brand)
        .accentColor(AppTheme.brand)
    }
}


