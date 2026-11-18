import SwiftUI

@main
struct IndianPianoApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .task { model.start() }
        }
    }
}
