import SwiftUI

@main
struct QuackleScrabbleApp: App {
    @State private var engine = QuackleEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
                .onAppear {
                    engine.initialize()
                }
        }
        #if os(macOS)
        .defaultSize(width: 500, height: 860)
        .windowResizability(.contentSize)
        #endif
    }
}
