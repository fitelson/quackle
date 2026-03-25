import SwiftUI

struct MoveInputView: View {
    @Environment(QuackleEngine.self) var engine
    @State private var showPassConfirmation = false
    @State private var showNewGameAlert = false

    var body: some View {
        VStack(spacing: 8) {
            // Row 1: Moves, History, Skill, New
            HStack(spacing: 10) {
                Button("Moves") {
                    engine.generateTopMoves()
                }
                .font(.system(size: 15))
                .buttonStyle(.bordered)
                .disabled(!engine.isHumanTurn || engine.isGameOver)

                Button("History") {
                    engine.showMoveHistory()
                }
                .font(.system(size: 15))
                .buttonStyle(.bordered)

                Button("Skill") {
                    engine.showSkillSlider = true
                }
                .font(.system(size: 15))
                .buttonStyle(.bordered)

                Button("New") {
                    showNewGameAlert = true
                }
                .font(.system(size: 15))
                .buttonStyle(.bordered)
            }

            // Row 2: Shuffle, Exchange, Pass
            HStack(spacing: 10) {
                Button("Shuffle") {
                    engine.shuffleRack()
                }
                .font(.system(size: 15))
                .buttonStyle(.bordered)

                Button("Exchange") {
                    engine.enterExchangeMode()
                }
                .font(.system(size: 15))
                .buttonStyle(.bordered)
                .disabled(!engine.isHumanTurn || engine.isGameOver || engine.tilesInBag < 7)

                Button("Pass") {
                    showPassConfirmation = true
                }
                .font(.system(size: 15))
                .buttonStyle(.bordered)
                .disabled(!engine.isHumanTurn || engine.isGameOver)
            }
        }
        .alert("Pass Turn?", isPresented: $showPassConfirmation) {
            Button("Pass", role: .destructive) {
                engine.pass()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to pass your turn?")
        }
        .alert("New Game", isPresented: $showNewGameAlert) {
            Button("Start New Game", role: .destructive) {
                engine.startNewGame()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to start a new game? Current game will be lost.")
        }
    }
}
