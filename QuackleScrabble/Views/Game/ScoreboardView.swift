import SwiftUI

struct ScoreboardView: View {
    @Environment(QuackleEngine.self) var engine

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                if engine.players.count > 0 {
                    VStack(spacing: 0) {
                        Text(engine.players[0].name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(engine.players[0].name == engine.currentPlayerName ? .blue : .primary)
                        Text("\(engine.players[0].score)")
                            .font(.system(size: 20, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                }

                if engine.players.count > 1 {
                    VStack(spacing: 0) {
                        Text(engine.players[1].name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(engine.players[1].name == engine.currentPlayerName ? .blue : .primary)
                        Text("\(engine.players[1].score)")
                            .font(.system(size: 20, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            HStack {
                Text("Bag: \(engine.tilesInBag)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                if engine.isGameOver {
                    Text("GAME OVER")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.red)
                } else if engine.gameMode == .multiplayer {
                    Text(engine.isLocalPlayerTurn ? "Your turn" : "Waiting...")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(engine.isLocalPlayerTurn ? .green : .orange)
                }
                Spacer()
                Text("Turn \(engine.turnNumber)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
        }

    }
}
