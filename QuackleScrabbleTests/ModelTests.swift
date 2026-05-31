import XCTest
@testable import Scrabble

final class ModelTests: XCTestCase {

    // MARK: - AI Skill

    @MainActor
    func testAISkillCalibration() {
        let engine = QuackleEngine()

        // skillLevel drives move quality (meanLoss/stdDev) only.
        engine.skillLevel = 0.0
        XCTAssertEqual(engine.skillMeanLoss, 20.0, accuracy: 0.0001)
        XCTAssertEqual(engine.skillStdDev, 8.0, accuracy: 0.0001)

        engine.skillLevel = 0.5
        XCTAssertEqual(engine.skillMeanLoss, 10.0, accuracy: 0.0001)
        XCTAssertEqual(engine.skillStdDev, 6.0, accuracy: 0.0001)

        engine.skillLevel = 1.0
        XCTAssertEqual(engine.skillMeanLoss, 2.0, accuracy: 0.0001)
        XCTAssertEqual(engine.skillStdDev, 2.0, accuracy: 0.0001)
    }

    @MainActor
    func testBingoKnowledgeIndependentOfSkill() {
        let engine = QuackleEngine()

        // Defaults to 0.10 and is NOT derived from skillLevel anymore.
        XCTAssertEqual(engine.bingoKnowledge, 0.10, accuracy: 0.0001)
        engine.skillLevel = 1.0
        XCTAssertEqual(engine.bingoKnowledge, 0.10, accuracy: 0.0001)

        // Independently settable.
        engine.bingoKnowledge = 0.5
        engine.skillLevel = 0.0
        XCTAssertEqual(engine.bingoKnowledge, 0.5, accuracy: 0.0001)
    }

    // MARK: - TileModel

    func testTilePointsCoverage() {
        // All 26 letters + blank should have point values
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ?"
        for char in letters {
            XCTAssertNotNil(TileModel.tilePoints[String(char)], "Missing points for '\(char)'")
        }
        // Spot-check known values
        XCTAssertEqual(TileModel.tilePoints["Q"], 10)
        XCTAssertEqual(TileModel.tilePoints["Z"], 10)
        XCTAssertEqual(TileModel.tilePoints["E"], 1)
        XCTAssertEqual(TileModel.tilePoints["?"], 0)
    }

    func testTileModelIdentity() {
        let a = TileModel(letter: "A", points: 1, isBlank: false)
        let b = TileModel(letter: "A", points: 1, isBlank: false)
        // Each tile gets a unique UUID
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - SavedTile / SavedGameState Codable

    func testSavedTileCodableRoundtrip() throws {
        let tile = SavedTile(letter: "X", isBlank: false)
        let data = try JSONEncoder().encode(tile)
        let decoded = try JSONDecoder().decode(SavedTile.self, from: data)
        XCTAssertEqual(decoded.letter, "X")
        XCTAssertFalse(decoded.isBlank)
    }

    func testSavedTileBlankCodableRoundtrip() throws {
        let tile = SavedTile(letter: "A", isBlank: true)
        let data = try JSONEncoder().encode(tile)
        let decoded = try JSONDecoder().decode(SavedTile.self, from: data)
        XCTAssertEqual(decoded.letter, "A")
        XCTAssertTrue(decoded.isBlank)
    }

    func testSavedGameStateCodableRoundtrip() throws {
        let history = [
            MoveHistoryEntry(turn: 1, playerName: "You", moveDescription: "8H HELLO", score: 16, totalScore: 16),
            MoveHistoryEntry(turn: 1, playerName: "AI", moveDescription: "7G WORLD", score: 20, totalScore: 20)
        ]
        let state = SavedGameState(
            humanFirst: true,
            skillLevel: 0.7,
            board: [[SavedTile(letter: "H", isBlank: false), nil], [nil, nil]],
            players: [
                SavedPlayer(name: "You", isHuman: true, score: 16, rack: ["A", "B"]),
                SavedPlayer(name: "AI", isHuman: false, score: 20, rack: ["C", "D"])
            ],
            bag: ["E", "F", "G"],
            isGameOver: false,
            isHumanTurn: true,
            moveHistory: history
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SavedGameState.self, from: data)

        XCTAssertTrue(decoded.humanFirst)
        XCTAssertEqual(decoded.skillLevel, 0.7, accuracy: 0.001)
        XCTAssertEqual(decoded.board.count, 2)
        XCTAssertEqual(decoded.board[0][0]?.letter, "H")
        XCTAssertNil(decoded.board[0][1])
        XCTAssertEqual(decoded.players.count, 2)
        XCTAssertEqual(decoded.players[0].name, "You")
        XCTAssertEqual(decoded.players[0].rack, ["A", "B"])
        XCTAssertEqual(decoded.bag, ["E", "F", "G"])
        XCTAssertFalse(decoded.isGameOver)
        XCTAssertTrue(decoded.isHumanTurn)
        XCTAssertEqual(decoded.moveHistory.count, 2)
        XCTAssertEqual(decoded.scorelessTurns, 0)  // default
        XCTAssertEqual(decoded.version, 1)
    }

    func testSavedGameStateRoundtripsScorelessTurns() throws {
        let state = SavedGameState(
            humanFirst: false, skillLevel: 0.5, board: [], players: [],
            bag: [], isGameOver: true, isHumanTurn: false, scorelessTurns: 4, moveHistory: []
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SavedGameState.self, from: data)
        XCTAssertEqual(decoded.scorelessTurns, 4)
        XCTAssertTrue(decoded.isGameOver)
    }

    func testSavedGameStateLegacyDecodeMissingFields() throws {
        // A payload from before `version`/`scorelessTurns` existed must still decode,
        // defaulting the new fields rather than silently discarding the saved game.
        let payload: [String: Any] = [
            "humanFirst": true,
            "skillLevel": 0.5,
            "board": [],
            "players": [],
            "bag": ["A"],
            "isGameOver": false,
            "isHumanTurn": true,
            "moveHistory": []
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(SavedGameState.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.scorelessTurns, 0)
        XCTAssertEqual(decoded.bag, ["A"])
    }

    func testMoveHistoryEntryLegacyDecodeMissingPlayerIndex() throws {
        // Pre-playerIndex entries must decode with playerIndex defaulting to -1.
        let payload: [String: Any] = [
            "id": UUID().uuidString,
            "turn": 2,
            "playerName": "You",
            "moveDescription": "8H CAT",
            "score": 10,
            "totalScore": 30
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(MoveHistoryEntry.self, from: data)
        XCTAssertEqual(decoded.playerIndex, -1)
        XCTAssertEqual(decoded.turn, 2)
        XCTAssertEqual(decoded.playerName, "You")
    }

    // MARK: - MoveHistoryEntry

    func testMoveHistoryEntryPreservesUUIDOnDecode() throws {
        let entry = MoveHistoryEntry(turn: 3, playerName: "You", moveDescription: "8H HELLO", score: 16, totalScore: 42)
        let originalID = entry.id

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(MoveHistoryEntry.self, from: data)

        // UUID should survive encode/decode roundtrip
        XCTAssertEqual(decoded.id, originalID)
        XCTAssertEqual(decoded.turn, 3)
        XCTAssertEqual(decoded.playerName, "You")
        XCTAssertEqual(decoded.moveDescription, "8H HELLO")
        XCTAssertEqual(decoded.score, 16)
        XCTAssertEqual(decoded.totalScore, 42)
    }

    func testMoveHistoryEntryPlayerIndexRoundtrip() throws {
        let entry = MoveHistoryEntry(turn: 1, playerIndex: 1, playerName: "Bob", moveDescription: "H8 DOG", score: 12, totalScore: 37)
        let decoded = try JSONDecoder().decode(MoveHistoryEntry.self, from: try JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.playerIndex, 1)
        // ...and inside a SavedGameState
        let saved = SavedGameState(humanFirst: true, skillLevel: 0.5, board: [], players: [],
                                   bag: [], isGameOver: false, isHumanTurn: true, moveHistory: [entry])
        let savedDecoded = try JSONDecoder().decode(SavedGameState.self, from: try JSONEncoder().encode(saved))
        XCTAssertEqual(savedDecoded.moveHistory.first?.playerIndex, 1)
    }

    func testSavedGameStateGameOverScorelessRoundtrip() throws {
        // The H2/scoreless persistence shape: game over with adjusted scores + scoreless count.
        let state = SavedGameState(
            humanFirst: true, skillLevel: 0.5,
            board: [[SavedTile(letter: "Q", isBlank: false)]],
            players: [SavedPlayer(name: "You", isHuman: true, score: 312, rack: []),
                      SavedPlayer(name: "AI", isHuman: false, score: 298, rack: ["A", "B"])],
            bag: [], isGameOver: true, isHumanTurn: false, scorelessTurns: 6,
            moveHistory: [MoveHistoryEntry(turn: 5, playerIndex: 0, playerName: "You", moveDescription: "out", score: 20, totalScore: 312)]
        )
        let decoded = try JSONDecoder().decode(SavedGameState.self, from: try JSONEncoder().encode(state))
        XCTAssertTrue(decoded.isGameOver)
        XCTAssertEqual(decoded.scorelessTurns, 6)
        XCTAssertEqual(decoded.players.map(\.score), [312, 298])
        XCTAssertEqual(decoded.moveHistory.first?.playerIndex, 0)
    }

    // MARK: - MultiplayerGameState Codable

    func testMultiplayerGameStateCodableRoundtrip() throws {
        let state = MultiplayerGameState(
            player1GameCenterID: "G:abc123",
            player2GameCenterID: "G:def456",
            player1DisplayName: "Alice",
            player2DisplayName: "Bob",
            board: [[nil, SavedTile(letter: "A", isBlank: false)], [nil, nil]],
            playerScores: [30, 25],
            playerRacks: [["X", "Y"], ["Z", "?"]],
            bag: ["A", "B", "C"],
            currentPlayerIndex: 1,
            turnNumber: 4,
            moveHistory: [
                MoveHistoryEntry(turn: 1, playerName: "Alice", moveDescription: "8H CAT", score: 10, totalScore: 10)
            ],
            isGameOver: false,
            consecutiveScorelessTurns: 0
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(MultiplayerGameState.self, from: data)

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.player1GameCenterID, "G:abc123")
        XCTAssertEqual(decoded.player2GameCenterID, "G:def456")
        XCTAssertEqual(decoded.player1DisplayName, "Alice")
        XCTAssertEqual(decoded.player2DisplayName, "Bob")
        XCTAssertEqual(decoded.playerScores, [30, 25])
        XCTAssertEqual(decoded.playerRacks, [["X", "Y"], ["Z", "?"]])
        XCTAssertEqual(decoded.bag, ["A", "B", "C"])
        XCTAssertEqual(decoded.currentPlayerIndex, 1)
        XCTAssertEqual(decoded.turnNumber, 4)
        XCTAssertEqual(decoded.moveHistory.count, 1)
        XCTAssertFalse(decoded.isGameOver)
        XCTAssertEqual(decoded.consecutiveScorelessTurns, 0)
        XCTAssertEqual(decoded.board[0][1]?.letter, "A")
        XCTAssertNil(decoded.board[0][0])
    }

    func testMultiplayerGameStateEmptyBoard() throws {
        let state = MultiplayerGameState(
            player1GameCenterID: "", player2GameCenterID: "",
            player1DisplayName: "P1", player2DisplayName: "P2",
            board: [], playerScores: [0, 0], playerRacks: [[], []],
            bag: [], currentPlayerIndex: 0, moveHistory: [],
            isGameOver: false, consecutiveScorelessTurns: 0
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(MultiplayerGameState.self, from: data)
        XCTAssertTrue(decoded.board.isEmpty)
        XCTAssertTrue(decoded.moveHistory.isEmpty)
        XCTAssertEqual(decoded.turnNumber, 1)
    }

    func testMultiplayerGameStateLegacyDecodeInfersPlayerTwoTurnNumber() throws {
        let history = [
            MoveHistoryEntry(turn: 3, playerName: "Alice", moveDescription: "8H CAT", score: 10, totalScore: 30)
        ]
        let payload: [String: Any] = [
            "version": 1,
            "player1GameCenterID": "G:abc123",
            "player2GameCenterID": "G:def456",
            "player1DisplayName": "Alice",
            "player2DisplayName": "Bob",
            "board": [],
            "playerScores": [30, 25],
            "playerRacks": [["A"], ["B"]],
            "bag": ["C"],
            "currentPlayerIndex": 1,
            "moveHistory": try JSONSerialization.jsonObject(with: JSONEncoder().encode(history)),
            "isGameOver": false,
            "consecutiveScorelessTurns": 2
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(MultiplayerGameState.self, from: data)
        XCTAssertEqual(decoded.turnNumber, 3)
    }

    func testMultiplayerGameStateLegacyDecodeInfersNextPlayerOneTurnNumber() throws {
        let history = [
            MoveHistoryEntry(turn: 3, playerName: "Alice", moveDescription: "8H CAT", score: 10, totalScore: 30),
            MoveHistoryEntry(turn: 3, playerName: "Bob", moveDescription: "H8 DOG", score: 12, totalScore: 37)
        ]
        let payload: [String: Any] = [
            "version": 1,
            "player1GameCenterID": "G:abc123",
            "player2GameCenterID": "G:def456",
            "player1DisplayName": "Alice",
            "player2DisplayName": "Bob",
            "board": [],
            "playerScores": [30, 37],
            "playerRacks": [["A"], ["B"]],
            "bag": ["C"],
            "currentPlayerIndex": 0,
            "moveHistory": try JSONSerialization.jsonObject(with: JSONEncoder().encode(history)),
            "isGameOver": false,
            "consecutiveScorelessTurns": 2
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(MultiplayerGameState.self, from: data)
        XCTAssertEqual(decoded.turnNumber, 4)
    }

    func testMultiplayerGameStateLegacyDecodeMissingVersion() throws {
        // A payload from before `version` existed must still decode, defaulting to 1.
        let payload: [String: Any] = [
            "player1GameCenterID": "G:abc123",
            "player2GameCenterID": "G:def456",
            "player1DisplayName": "Alice",
            "player2DisplayName": "Bob",
            "board": [],
            "playerScores": [0, 0],
            "playerRacks": [["A"], ["B"]],
            "bag": ["C"],
            "currentPlayerIndex": 0,
            "moveHistory": [],
            "isGameOver": false,
            "consecutiveScorelessTurns": 0
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(MultiplayerGameState.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        // Empty history + player-1 to move → inferred turn 1.
        XCTAssertEqual(decoded.turnNumber, 1)
    }

    func testMultiplayerGameStateInferredTurnNumberZeroTurnHistory() throws {
        // History with only turn-0 entries (pregame) → inferred turn 1, not 0/+1.
        let history = [MoveHistoryEntry(turn: 0, playerName: "Alice", moveDescription: "--", score: 0, totalScore: 0)]
        let payload: [String: Any] = [
            "player1GameCenterID": "G:abc123",
            "player2GameCenterID": "G:def456",
            "player1DisplayName": "Alice",
            "player2DisplayName": "Bob",
            "board": [],
            "playerScores": [0, 0],
            "playerRacks": [["A"], ["B"]],
            "bag": ["C"],
            "currentPlayerIndex": 1,
            "moveHistory": try JSONSerialization.jsonObject(with: JSONEncoder().encode(history)),
            "isGameOver": false,
            "consecutiveScorelessTurns": 0
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(MultiplayerGameState.self, from: data)
        XCTAssertEqual(decoded.turnNumber, 1)
    }

    func testMultiplayerGameStateDecodesMissingScorelessAndGameOver() throws {
        // Finding #2: a payload from before these fields existed must decode with defaults
        // (consecutiveScorelessTurns → 0, isGameOver → false), matching SavedGameState's posture.
        let payload: [String: Any] = [
            "version": 1,
            "player1GameCenterID": "G:abc123",
            "player2GameCenterID": "G:def456",
            "player1DisplayName": "Alice",
            "player2DisplayName": "Bob",
            "board": [],
            "playerScores": [0, 0],
            "playerRacks": [["A"], ["B"]],
            "bag": ["C"],
            "currentPlayerIndex": 0,
            "moveHistory": []
            // deliberately NO isGameOver and NO consecutiveScorelessTurns
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(MultiplayerGameState.self, from: data)
        XCTAssertFalse(decoded.isGameOver)
        XCTAssertEqual(decoded.consecutiveScorelessTurns, 0)
    }

    // MARK: - Multiplayer state structural validation (Finding #3 preflight)

    func testMultiplayerStateStructuralValidation() {
        let emptyRow: [SavedTile?] = Array(repeating: nil, count: 15)
        let board15: [[SavedTile?]] = Array(repeating: emptyRow, count: 15)
        let rack = ["A", "B", "C", "D", "E", "F", "G"]          // 7 tiles
        let bag86 = Array(repeating: "Z", count: 86)            // 7 + 7 + 86 = 100
        func mk(board: [[SavedTile?]] = board15, racks: [[String]] = [rack, rack],
                scores: [Int] = [0, 0], bag: [String] = bag86, current: Int = 0) -> MultiplayerGameState {
            MultiplayerGameState(
                player1GameCenterID: "G:a", player2GameCenterID: "G:b",
                player1DisplayName: "A", player2DisplayName: "B",
                board: board, playerScores: scores, playerRacks: racks, bag: bag,
                currentPlayerIndex: current, moveHistory: [], isGameOver: false,
                consecutiveScorelessTurns: 0)
        }
        // Valid opening position: 0 board + 14 rack + 86 bag = 100 tiles, 15×15, current 0.
        XCTAssertTrue(QuackleEngine.isStructurallyValidMultiplayerState(mk()))
        // 99 tiles (bag short by one) → rejected by tile conservation.
        XCTAssertFalse(QuackleEngine.isStructurallyValidMultiplayerState(mk(bag: Array(repeating: "Z", count: 85))))
        // Wrong board dimensions (14 rows) → rejected.
        XCTAssertFalse(QuackleEngine.isStructurallyValidMultiplayerState(mk(board: Array(repeating: emptyRow, count: 14))))
        // currentPlayerIndex outside {0,1} → rejected.
        XCTAssertFalse(QuackleEngine.isStructurallyValidMultiplayerState(mk(current: 2)))
        // Wrong rack count → rejected.
        XCTAssertFalse(QuackleEngine.isStructurallyValidMultiplayerState(mk(racks: [rack])))
    }

    // MARK: - GameRecord (game history)

    func testGameRecordCodableRoundtrip() throws {
        let rec = GameRecord(id: "m1", date: Date(timeIntervalSince1970: 1_700_000_000),
                             isOnline: true, localName: "fitelson", opponentName: "Tina",
                             localScore: 321, opponentScore: 288, board: "A.b", cols: 3)
        let data = try JSONEncoder().encode(rec)
        let decoded = try JSONDecoder().decode(GameRecord.self, from: data)
        XCTAssertEqual(decoded.id, "m1")
        XCTAssertEqual(decoded.isOnline, true)
        XCTAssertEqual(decoded.localScore, 321)
        XCTAssertEqual(decoded.opponentScore, 288)
        XCTAssertEqual(decoded.result, .won)
    }

    func testGameRecordResult() {
        func r(_ a: Int, _ b: Int) -> GameRecord.Result {
            GameRecord(id: "x", date: Date(), isOnline: false, localName: "You", opponentName: "AI",
                       localScore: a, opponentScore: b, board: "", cols: 0).result
        }
        XCTAssertEqual(r(10, 5), .won)
        XCTAssertEqual(r(5, 10), .lost)
        XCTAssertEqual(r(7, 7), .tied)
    }

    func testGameRecordBoardEncodeDecodeRoundtrip() {
        // 2x3 board: A (tile), empty, e (blank-E); empty, B, empty
        let board: [[SquareModel]] = [
            [SquareModel(letter: "A", isBlank: false, bonus: .none),
             SquareModel(letter: nil, isBlank: false, bonus: .none),
             SquareModel(letter: "E", isBlank: true,  bonus: .none)],
            [SquareModel(letter: nil, isBlank: false, bonus: .none),
             SquareModel(letter: "B", isBlank: false, bonus: .none),
             SquareModel(letter: nil, isBlank: false, bonus: .none)],
        ]
        let encoded = GameRecord.encodeBoard(board)
        XCTAssertEqual(encoded, "A.e.B.")   // '.'=empty, lowercase=blank
        let rec = GameRecord(id: "x", date: Date(), isOnline: false, localName: "You",
                             opponentName: "AI", localScore: 0, opponentScore: 0,
                             board: encoded, cols: 3)
        let grid = rec.boardGrid()
        XCTAssertEqual(grid.count, 2)
        XCTAssertEqual(grid[0][0]?.letter, "A")
        XCTAssertEqual(grid[0][0]?.isBlank, false)
        XCTAssertNil(grid[0][1] ?? nil)
        XCTAssertEqual(grid[0][2]?.letter, "E")
        XCTAssertEqual(grid[0][2]?.isBlank, true)
        XCTAssertEqual(grid[1][1]?.letter, "B")
    }

    // MARK: - GameHistoryStore (tombstone / dedup / migration / prune) — fake KVS

    private func rec(_ id: String, _ t: TimeInterval) -> GameRecord {
        GameRecord(id: id, date: Date(timeIntervalSince1970: t), isOnline: true,
                   localName: "You", opponentName: "Tina", localScore: 1, opponentScore: 0,
                   board: "", cols: 0)
    }

    @MainActor
    func testRecordRefusesTombstonedID() {
        let kv = InMemoryKeyValueStore()
        let store = GameHistoryStore(store: kv)
        let g = rec("g1", 1)
        store.record(g)
        XCTAssertEqual(store.games.count, 1)
        store.delete(g)
        XCTAssertTrue(store.games.isEmpty)
        store.record(g)                              // re-record a deleted game
        XCTAssertTrue(store.games.isEmpty)           // refused — stays deleted
        XCTAssertNil(kv.data(forKey: "ghRec_g1"))    // no record key rewritten
    }

    @MainActor
    func testContainsTrueForTombstonedID() {
        let kv = InMemoryKeyValueStore()
        let store = GameHistoryStore(store: kv)
        let g = rec("g1", 1)
        store.record(g)
        XCTAssertTrue(store.contains("g1"))
        store.delete(g)
        XCTAssertTrue(store.contains("g1"))          // tombstone-aware: still "contained"
        XCTAssertFalse(store.contains("nope"))
    }

    @MainActor
    func testLegacyArrayMigrationSkipsTombstoned() throws {
        let kv = InMemoryKeyValueStore()
        kv.setData(try JSONEncoder().encode([rec("g1", 1), rec("g2", 2)]), forKey: "gameHistory")
        kv.setString("1", forKey: "ghDel_g1")        // g1 was deleted before migration
        let store = GameHistoryStore(store: kv)      // runs migration on init
        XCTAssertEqual(store.games.map(\.id), ["g2"])
        XCTAssertNil(kv.data(forKey: "ghRec_g1"))    // tombstoned id not migrated back
        XCTAssertNotNil(kv.data(forKey: "ghRec_g2"))
        XCTAssertNil(kv.data(forKey: "gameHistory")) // legacy key consumed
    }

    @MainActor
    func testReloadExcludesTombstoned() throws {
        let kv = InMemoryKeyValueStore()
        kv.setData(try JSONEncoder().encode(rec("g1", 1)), forKey: "ghRec_g1")
        kv.setString("1", forKey: "ghDel_g1")        // record key AND tombstone present
        let store = GameHistoryStore(store: kv)
        XCTAssertTrue(store.games.isEmpty)           // reload excludes the tombstoned record
    }

    @MainActor
    func testDeleteAllRemovesBeyondDisplayCap() throws {
        // 250 stored records: more than maxDisplay (200), fewer than maxStored (400). deleteAll
        // must clear ALL of them — iterating the displayed `games` (200) would orphan the rest.
        let kv = InMemoryKeyValueStore()
        for i in 0..<250 { kv.setData(try JSONEncoder().encode(rec("g\(i)", TimeInterval(i))), forKey: "ghRec_g\(i)") }
        let store = GameHistoryStore(store: kv)
        XCTAssertEqual(store.games.count, 200)                                       // display-capped
        XCTAssertEqual(kv.allEntries.keys.filter { $0.hasPrefix("ghRec_") }.count, 250)
        store.deleteAll()
        XCTAssertTrue(store.games.isEmpty)
        XCTAssertEqual(kv.allEntries.keys.filter { $0.hasPrefix("ghRec_") }.count, 0) // ALL cleared
    }

    @MainActor
    func testMaxStoredPrunesOldest() throws {
        // 410 stored records (> maxStored 400): reload prunes the 10 oldest record keys.
        let kv = InMemoryKeyValueStore()
        for i in 0..<410 { kv.setData(try JSONEncoder().encode(rec("g\(i)", TimeInterval(i))), forKey: "ghRec_g\(i)") }
        let store = GameHistoryStore(store: kv)
        XCTAssertEqual(kv.allEntries.keys.filter { $0.hasPrefix("ghRec_") }.count, 400)
        XCTAssertNil(kv.data(forKey: "ghRec_g0"))      // oldest pruned
        XCTAssertNil(kv.data(forKey: "ghRec_g9"))
        XCTAssertNotNil(kv.data(forKey: "ghRec_g10"))  // survivor
        XCTAssertEqual(store.games.count, 200)         // display still capped
        XCTAssertEqual(store.games.first?.id, "g409")  // newest first
    }

    // MARK: - loadSavedGame integrity (tile conservation)

    @MainActor
    func testLoadSavedGameRejectsInvalidTileCountAndClearsSave() throws {
        let key = "savedGameState"
        let defaults = UserDefaults.standard
        let original = defaults.data(forKey: key)
        defer {   // never clobber a real in-progress save when running on a dev machine
            if let o = original { defaults.set(o, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        // A save whose tiles don't sum to 100 (here: 1) must be rejected and cleared, not loaded.
        let bad = SavedGameState(humanFirst: true, skillLevel: 0.5, board: [], players: [],
                                 bag: ["A"], isGameOver: false, isHumanTurn: true, moveHistory: [])
        defaults.set(try JSONEncoder().encode(bad), forKey: key)
        let engine = QuackleEngine()
        XCTAssertFalse(engine.loadSavedGame())      // rejected before any bridge restore
        XCTAssertNil(defaults.data(forKey: key))    // corrupt save auto-healed away
    }

    // MARK: - AI skill interpolation (non-anchor points)

    @MainActor
    func testAISkillInterpolatesBetweenAnchors() {
        let engine = QuackleEngine()
        engine.skillLevel = 0.25                     // halfway between anchors 0 and 0.5
        XCTAssertEqual(engine.skillMeanLoss, 15.0, accuracy: 0.0001)  // 20 → 10
        XCTAssertEqual(engine.skillStdDev, 7.0, accuracy: 0.0001)     // 8 → 6
        engine.skillLevel = 0.75                     // halfway between anchors 0.5 and 1
        XCTAssertEqual(engine.skillMeanLoss, 6.0, accuracy: 0.0001)   // 10 → 2
        XCTAssertEqual(engine.skillStdDev, 4.0, accuracy: 0.0001)     // 6 → 2
    }
}

/// In-memory `KeyValueStore` so GameHistoryStore can be tested deterministically without the
/// real (process-wide, non-deterministic) iCloud key-value store.
final class InMemoryKeyValueStore: KeyValueStore {
    private var storage: [String: Any] = [:]
    func data(forKey key: String) -> Data? { storage[key] as? Data }
    func string(forKey key: String) -> String? { storage[key] as? String }
    func setData(_ data: Data, forKey key: String) { storage[key] = data }
    func setString(_ string: String, forKey key: String) { storage[key] = string }
    func removeObject(forKey key: String) { storage.removeValue(forKey: key) }
    var allEntries: [String: Any] { storage }
    @discardableResult func synchronize() -> Bool { true }
}
