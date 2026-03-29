import SwiftUI

struct ContentView: View {
    @Environment(QuackleEngine.self) var engine

    @Environment(GameCenterManager.self) var gameCenterManager

    var body: some View {
        Group {
            if !engine.isInitialized {
                VStack(spacing: 16) {
                    Text("Quackle")
                        .font(.system(size: 28, weight: .bold))

                    ProgressView(value: engine.loadingProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 200)

                    Text(engine.loadingStatus)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)

                    if let error = engine.errorMessage {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                    }
                }
                .padding()
                #if os(macOS)
                .frame(width: 500, height: 860)
                #endif
            } else if engine.showModeSelection {
                ModeSelectionView()
            } else if gameCenterManager.isWaitingForOpponent {
                WaitingForOpponentView()
            } else {
                GameView()
            }
        }
    }
}

struct GameView: View {
    @Environment(QuackleEngine.self) var engine
    @Environment(GameCenterManager.self) var gameCenterManager
    let pollTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        @Bindable var engine = engine

        VStack(spacing: 8) {
            ScoreboardView()
                .padding(.top, 4)

            BoardView()
                .padding(.horizontal, 2)

            OpponentRackView()

            Spacer(minLength: 0)

            // Submit/Clear row between board and rack
            if engine.isExchangeMode {
                HStack(spacing: 12) {
                    Button("Confirm Exchange") {
                        engine.commitExchange()
                    }
                    .font(.system(size: 18, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.large)
                    .disabled(engine.exchangeSelectedIds.isEmpty)

                    Button("Cancel") {
                        engine.cancelExchange()
                    }
                    .font(.system(size: 16))
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            } else if !engine.tentativePlacements.isEmpty {
                let isHypothetical = engine.gameMode == .multiplayer && !engine.isLocalPlayerTurn
                HStack(spacing: 12) {
                    if engine.isTentativeMoveValid {
                        if isHypothetical {
                            Text("Score: \(engine.tentativeMoveScore)")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.orange)
                        } else {
                            Button("Submit (\(engine.tentativeMoveScore))") {
                                engine.commitTentativeMove()
                            }
                            .font(.system(size: 20, weight: .bold))
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .controlSize(.large)
                        }
                    }

                    Button("Clear") {
                        engine.clearTentativePlacements()
                    }
                    .font(.system(size: 16))
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }

            if engine.isGameOver {
                Text("GAME OVER")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.red)
            }

            RackView()

            MoveInputView()
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 16)
        .coordinateSpace(name: "game")
        .overlay {
            if engine.activeDragSource != nil {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(red: 1.0, green: 0.92, blue: 0.80))
                        .frame(width: 44, height: 44)
                        .shadow(radius: 3)

                    Text(engine.activeDragIsBlank ? "?" : engine.activeDragLetter)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.black)

                    if !engine.activeDragIsBlank {
                        Text("\(engine.activeDragPoints)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.black.opacity(0.6))
                            .padding(3)
                            .frame(width: 44, height: 44, alignment: .bottomTrailing)
                    }
                }
                .position(engine.activeDragLocation)
                .allowsHitTesting(false)
            }
        }
        .overlay {
            if engine.isAnimatingAIMove {
                AIAnimationOverlay()
                    .environment(engine)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if engine.showHandoff {
                HandoffView()
                    .environment(engine)
            }
        }
        #if os(macOS)
        .frame(width: 500, height: 860)
        #endif
        .sheet(isPresented: $engine.showBlankPicker) {
            BlankPickerView()
                .environment(engine)
                #if os(iOS)
                .presentationDetents([.medium])
                #endif
        }
        .sheet(isPresented: $engine.showMoves) {
            TopMovesView()
                .environment(engine)
                #if os(iOS)
                .presentationDetents([.large])
                .interactiveDismissDisabled()
                #endif
        }
        .sheet(isPresented: $engine.showHistory) {
            HistoryView()
                .environment(engine)
                #if os(iOS)
                .presentationDetents([.large])
                #endif
        }
        .sheet(isPresented: $engine.showSkillSlider) {
            SkillSliderView()
                .environment(engine)
                #if os(iOS)
                .presentationDetents([.height(200)])
                #endif
        }
        .onReceive(pollTimer) { _ in
            if engine.gameMode == .multiplayer && !engine.isLocalPlayerTurn && !engine.isGameOver {
                gameCenterManager.pollForMatchUpdate()
            }
        }
    }
}

struct BlankPickerView: View {
    @Environment(QuackleEngine.self) var engine
    @Environment(\.dismiss) var dismiss

    let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)

    var body: some View {
        VStack(spacing: 12) {
            Text("Choose letter for blank")
                .font(.headline)
                .padding(.top)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(letters, id: \.self) { letter in
                    Button {
                        let chosen = String(letter)
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            engine.placeBlankAs(letter: chosen)
                        }
                    } label: {
                        Text(String(letter))
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.black)
                            .frame(width: 40, height: 40)
                            .background(Color(red: 1.0, green: 0.92, blue: 0.80))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()

            Button("Cancel") {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    engine.showBlankPicker = false
                }
            }
            .padding(.bottom)
        }
        #if os(macOS)
        .frame(width: 350, height: 280)
        #endif
    }
}

struct TopMovesView: View {
    @Environment(QuackleEngine.self) var engine
    @Environment(\.dismiss) var dismiss

    var body: some View {
        #if os(iOS)
        NavigationStack {
            List(Array(engine.topMoves.enumerated()), id: \.element.id) { index, move in
                HStack {
                    Text(move.description)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(move.score)")
                        .frame(width: 50, alignment: .trailing)
                    Text(String(format: "%.1f", move.equity))
                        .frame(width: 60, alignment: .trailing)
                }
                .font(.system(size: 14))
            }
            .listStyle(.plain)
            .navigationTitle("Top Moves")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #else
        VStack(spacing: 0) {
            HStack {
                Text("Top Moves")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            // Header
            HStack {
                Text("Move")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Score")
                    .frame(width: 50, alignment: .trailing)
                Text("Equity")
                    .frame(width: 60, alignment: .trailing)
            }
            .font(.system(size: 12, weight: .bold))
            .padding(.horizontal)
            .padding(.vertical, 4)
            .background(Color.gray.opacity(0.2))

            List(Array(engine.topMoves.enumerated()), id: \.element.id) { index, move in
                HStack {
                    Text(move.description)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(move.score)")
                        .frame(width: 50, alignment: .trailing)
                    Text(String(format: "%.1f", move.equity))
                        .frame(width: 60, alignment: .trailing)
                }
                .font(.system(size: 14))
            }
            .listStyle(.plain)
        }
        .frame(width: 450, height: 500)
        #endif
    }
}

struct HistoryView: View {
    @Environment(QuackleEngine.self) var engine
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Move History")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            if engine.moveHistory.isEmpty {
                Text("No moves yet")
                    .foregroundColor(.secondary)
                    .padding()
                Spacer()
            } else {
                // Header
                HStack {
                    Text("#")
                        .frame(width: 25, alignment: .leading)
                    Text("Player")
                        .frame(width: 65, alignment: .leading)
                    Text("Move")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("+Pts")
                        .frame(width: 40, alignment: .trailing)
                    Text("Total")
                        .frame(width: 45, alignment: .trailing)
                }
                .font(.system(size: 12, weight: .bold))
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.2))

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(engine.moveHistory.enumerated()), id: \.element.id) { index, entry in
                            HStack {
                                Text("\(entry.turn)")
                                    .frame(width: 25, alignment: .leading)
                                Text(entry.playerName)
                                    .frame(width: 65, alignment: .leading)
                                    .foregroundColor(entry.playerName == "You" ? .blue : .primary)
                                Text(entry.moveDescription)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("+\(entry.score)")
                                    .frame(width: 40, alignment: .trailing)
                                Text("\(entry.totalScore)")
                                    .frame(width: 45, alignment: .trailing)
                                    .fontWeight(.semibold)
                            }
                            .font(.system(size: 13))
                            .padding(.horizontal)
                            .padding(.vertical, 5)
                            .background(index % 2 == 0 ? Color.clear : Color.gray.opacity(0.1))
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 450, height: 500)
        #endif
    }
}

struct SkillSliderView: View {
    @Environment(QuackleEngine.self) var engine
    @Environment(\.dismiss) var dismiss

    var body: some View {
        @Bindable var engine = engine

        VStack(spacing: 16) {
            Text("AI Skill: \(String(format: "%.1f", engine.skillLevel))")
                .font(.headline)
                .padding(.top)

            HStack {
                Text("Low")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Slider(value: $engine.skillLevel, in: 0...1, step: 0.1)
                Text("High")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)

            Text("Takes effect on next new game")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Button("Done") { dismiss() }
                .padding(.bottom)
        }
        #if os(macOS)
        .frame(width: 350, height: 180)
        #endif
    }
}

struct WaitingForOpponentView: View {
    @Environment(QuackleEngine.self) var engine
    @Environment(GameCenterManager.self) var gameCenterManager
    let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            Text("Waiting for opponent...")
                .font(.system(size: 20, weight: .semibold))

            Text("They're making the first move")
                .font(.system(size: 14))
                .foregroundColor(.secondary)

            Spacer()

            Button("Cancel") {
                engine.showModeSelection = true
            }
            .font(.system(size: 16))
            .buttonStyle(.bordered)
            .padding(.bottom, 40)
        }
        .padding()
        #if os(macOS)
        .frame(width: 500, height: 860)
        #endif
        .onReceive(timer) { _ in
            gameCenterManager.pollForMatchUpdate()
        }
    }
}

struct HandoffView: View {
    @Environment(QuackleEngine.self) var engine

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 48))
                    .foregroundColor(.white)

                Text("Hand device to")
                    .font(.system(size: 18))
                    .foregroundColor(.white.opacity(0.7))

                Text(engine.handoffPlayerName)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)

                Button {
                    engine.dismissHandoff()
                } label: {
                    Text("Ready")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 160, height: 50)
                        .background(Color.blue)
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            }
        }
    }
}
