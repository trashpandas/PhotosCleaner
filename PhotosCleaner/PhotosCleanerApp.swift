import SwiftUI

@main
struct PhotosCleanerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 720, height: 600)
        .commands {
            // Remove File > New Window — this app is single-window
            CommandGroup(replacing: .newItem) {}
        }
    }
}
