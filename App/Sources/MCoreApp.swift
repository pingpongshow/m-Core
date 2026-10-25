import SwiftUI

@main
struct MCoreApp: App {
    @State private var radio = RadioConnectionModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(radio)
        }
    }
}
