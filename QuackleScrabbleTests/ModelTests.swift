import XCTest
@testable import Scrabble

final class ModelTests: XCTestCase {

    // MARK: - AI Skill

    @MainActor
    func testAISkillCalibration() {
        let engine = QuackleEngine()

        engine.skillLevel = 0.0
        XCTAssertEqual(engine.skillMeanLoss, 20.0, accuracy: 0.0001)
        XCTAssertEqual(engine.skillStdDev, 8.0, accuracy: 0.0001)
        XCTAssertEqual(engine.bingoKnowledge, 0.0, accuracy: 0.0001)

        engine.skillLevel = 0.5
        XCTAssertEqual(engine.skillMeanLoss, 10.0, accuracy: 0.0001)
        XCTAssertEqual(engine.skillStdDev, 6.0, accuracy: 0.0001)
        XCTAssertEqual(engine.bingoKnowledge, 0.10, accuracy: 0.0001)

        engine.skillLevel = 1.0
        XCTAssertEqual(engine.skillMeanLoss, 2.0, accuracy: 0.0001)
        XCTAssertEqual(engine.skillStdDev, 2.0, accuracy: 0.0001)
        XCTAssertEqual(engine.bingoKnowledge, 1.0, accuracy: 0.0001)
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
}
