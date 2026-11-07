import SwiftUI

@main
struct AchtungApp: App {
    var body: some Scene {
        WindowGroup {
            InboxView(channels: SampleData.channels)
        }
    }
}
