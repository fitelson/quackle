import SwiftUI
import GameKit

struct ModeSelectionView: View {
    @Environment(QuackleEngine.self) var engine
    @Environment(GameCenterManager.self) var gameCenterManager
    @State private var showNameEntry = false
    @State private var player1Name = "Player 1"
    @State private var player2Name = "Player 2"

    var body: some View {
        VStack(spacing: 24) {
            Text("Scrabble")
                .font(.system(size: 32, weight: .bold))

            VStack(spacing: 14) {
                Button {
                    engine.startNewGame()
                } label: {
                    HStack {
                        Image(systemName: "desktopcomputer")
                        Text("Play vs AI")
                    }
                    .font(.system(size: 18, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                Button {
                    showNameEntry = true
                } label: {
                    HStack {
                        Image(systemName: "person.2.fill")
                        Text("Pass & Play")
                    }
                    .font(.system(size: 18, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button {
                    gameCenterManager.findOrCreateMatch()
                } label: {
                    HStack {
                        if gameCenterManager.isFinding {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Finding match...")
                        } else {
                            Image(systemName: "wifi")
                            Text("Play Online")
                        }
                    }
                    .font(.system(size: 18, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!gameCenterManager.isAuthenticated || gameCenterManager.isFinding)

                if !gameCenterManager.isAuthenticated {
                    if let error = gameCenterManager.authError {
                        Text("Game Center: \(error)")
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                    } else {
                        Text("Signing into Game Center...")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                if let error = engine.errorMessage {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
            }
            .frame(width: 240)
        }
        .padding()
        #if os(macOS)
        .frame(width: 500, height: 860)
        #endif
        .alert("Player Names", isPresented: $showNameEntry) {
            TextField("Player 1", text: $player1Name)
            TextField("Player 2", text: $player2Name)
            Button("Start") {
                let p1 = player1Name.trimmingCharacters(in: .whitespaces)
                let p2 = player2Name.trimmingCharacters(in: .whitespaces)
                engine.startPassAndPlayGame(
                    player1Name: p1.isEmpty ? "Player 1" : p1,
                    player2Name: p2.isEmpty ? "Player 2" : p2
                )
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter names for both players")
        }
    }
}
