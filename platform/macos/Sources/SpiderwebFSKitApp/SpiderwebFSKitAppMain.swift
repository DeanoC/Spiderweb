import SwiftUI

@available(macOS 15.4, *)
@main
struct SpiderwebFSKitAppMain: App {
    @StateObject private var controller = SpiderwebFSKitAppController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
        }
    }
}
