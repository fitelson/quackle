import SwiftUI

struct ContentView: View {
    @Environment(QuackleEngine.self) var engine

    var body: some View {
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
        } else {
            GameView()
        }
    }
}

struct GameView: View {
    @Environment(QuackleEngine.self) var engine

    var body: some View {
        @Bindable var engine = engine

        VStack(spacing: 8) {
            ScoreboardView()
                .padding(.top, 4)

            BoardView()
                .padding(.horizontal, 2)

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
                VStack(spacing: 6) {
                    if engine.isTentativeMoveValid {
                        Button("Submit") {
                            engine.commitTentativeMove()
                        }
                        .font(.system(size: 20, weight: .bold))
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.large)
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
        .sheet(isPresented: $engine.showBlankPicker) {
            BlankPickerView()
                .environment(engine)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $engine.showMoves) {
            TopMovesView()
                .environment(engine)
                .presentationDetents([.large])
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $engine.showHistory) {
            HistoryView()
                .environment(engine)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $engine.showSkillSlider) {
            SkillSliderView()
                .environment(engine)
                .presentationDetents([.height(200)])
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
    }
}

struct TopMovesView: View {
    @Environment(QuackleEngine.self) var engine
    @Environment(\.dismiss) var dismiss

    var body: some View {
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
    }
}
