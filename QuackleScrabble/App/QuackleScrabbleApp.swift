import SwiftUI

@main
struct QuackleScrabbleApp: App {
    @State private var engine = QuackleEngine()
    @State private var gameCenterManager = GameCenterManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
                .environment(gameCenterManager)
                .onAppear {
                    gameCenterManager.engine = engine
                    gameCenterManager.authenticate()
                    engine.initialize()
                }
        }
        #if os(macOS)
        .defaultSize(width: 500, height: 860)
        .windowResizability(.contentSize)
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                if engine.gameMode == .ai {
                    engine.saveGameState()
                }
            } else if phase == .active {
                gameCenterManager.retryPendingTurn()
            }
        }
    }

}
