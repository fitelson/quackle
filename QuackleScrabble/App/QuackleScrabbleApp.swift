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
                    setupMultiplayerCallback()
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

    private func setupMultiplayerCallback() {
        engine.onMultiplayerMoveCommitted = { [weak engine, weak gameCenterManager] in
            guard let engine, let gameCenterManager else { return }
            print("[Multiplayer] Move committed, exporting state...")
            let state = engine.exportMultiplayerState()
            guard let data = try? JSONEncoder().encode(state) else {
                print("[Multiplayer] ERROR: Failed to encode state")
                return
            }
            print("[Multiplayer] State encoded: \(data.count) bytes, gameOver=\(engine.isGameOver)")
            if engine.isGameOver {
                let localIdx = engine.localPlayerIndex
                let localScore = state.playerScores[localIdx]
                let opponentScore = state.playerScores[localIdx == 0 ? 1 : 0]
                gameCenterManager.endMatch(matchData: data, localWon: localScore > opponentScore)
            } else {
                gameCenterManager.submitTurn(matchData: data)
            }
        }
    }
}
