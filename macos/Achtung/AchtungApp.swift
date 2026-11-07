import SwiftUI

@main
struct AchtungApp: App {
    var body: some Scene {
        WindowGroup {
            InboxView(inbox: SampleData.inbox())
                .frame(minWidth: 900, minHeight: 500)
        }
    }
}
