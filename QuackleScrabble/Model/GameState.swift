import Foundation
import Observation

struct TilePlacement: Equatable {
    let row: Int
    let col: Int
    let letter: String
    let isBlank: Bool
}

struct AIAnimTile: Identifiable {
    let id = UUID()
    let letter: String
    let isBlank: Bool
    let points: Int
    let targetRow: Int
    let targetCol: Int
    let rackIndex: Int  // which opponent rack slot this tile comes from
}

struct MoveHistoryEntry: Identifiable, Codable {
    let id: UUID
    let turn: Int
    /// Player index (0 or 1) the move belongs to. -1 for legacy entries decoded
    /// from data written before this field existed.
    let playerIndex: Int
    let playerName: String
    let moveDescription: String
    let score: Int
    let totalScore: Int

    init(turn: Int, playerIndex: Int = -1, playerName: String, moveDescription: String, score: Int, totalScore: Int) {
        self.id = UUID()
        self.turn = turn
        self.playerIndex = playerIndex
        self.playerName = playerName
        self.moveDescription = moveDescription
        self.score = score
        self.totalScore = totalScore
    }

    enum CodingKeys: String, CodingKey {
        case id, turn, playerIndex, playerName, moveDescription, score, totalScore
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        turn = try c.decode(Int.self, forKey: .turn)
        // Legacy data (match data / saved AI games) predates playerIndex.
        playerIndex = try c.decodeIfPresent(Int.self, forKey: .playerIndex) ?? -1
        playerName = try c.decode(String.self, forKey: .playerName)
        moveDescription = try c.decode(String.self, forKey: .moveDescription)
        score = try c.decode(Int.self, forKey: .score)
        totalScore = try c.decode(Int.self, forKey: .totalScore)
    }
}

// MARK: - Game State Persistence

struct SavedTile: Codable {
    let letter: String
    let isBlank: Bool
}

struct SavedPlayer: Codable {
    let name: String
    let isHuman: Bool
    let score: Int
    let rack: [String]
}

struct SavedGameState: Codable {
    let version: Int
    let humanFirst: Bool
    let skillLevel: Double
    /// Fraction (0–1) of bingo words the AI knows — independent of skillLevel.
    /// Defaults to 0.10 for saves from before the two-slider split.
    let bingoKnowledge: Double
    let board: [[SavedTile?]]
    let players: [SavedPlayer]
    let bag: [String]
    let isGameOver: Bool
    let isHumanTurn: Bool
    /// Consecutive scoreless turns (for the six-scoreless game-end rule). Defaults to
    /// 0 when decoding a payload from before this field existed.
    let scorelessTurns: Int
    /// Current C++ turn number, restored so post-restore moves continue the sequence
    /// (otherwise the bridge restarts at 1 and new history entries collide with saved
    /// ones on the (turn, playerIndex) dedup key). Defaults to 1 for legacy saves.
    let turnNumber: Int
    let moveHistory: [MoveHistoryEntry]

    init(humanFirst: Bool, skillLevel: Double, bingoKnowledge: Double = 0.10,
         board: [[SavedTile?]], players: [SavedPlayer],
         bag: [String], isGameOver: Bool, isHumanTurn: Bool, scorelessTurns: Int = 0,
         turnNumber: Int = 1, moveHistory: [MoveHistoryEntry], version: Int = 1) {
        self.version = version
        self.humanFirst = humanFirst
        self.skillLevel = skillLevel
        self.bingoKnowledge = bingoKnowledge
        self.board = board
        self.players = players
        self.bag = bag
        self.isGameOver = isGameOver
        self.isHumanTurn = isHumanTurn
        self.scorelessTurns = scorelessTurns
        self.turnNumber = turnNumber
        self.moveHistory = moveHistory
    }

    enum CodingKeys: String, CodingKey {
        case version, humanFirst, skillLevel, bingoKnowledge, board, players, bag, isGameOver, isHumanTurn, scorelessTurns, turnNumber, moveHistory
    }

    // Custom decoder: tolerate older saves that lack newer fields (decodeIfPresent +
    // defaults) so a schema addition never silently discards an in-progress AI game.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        humanFirst = try c.decode(Bool.self, forKey: .humanFirst)
        skillLevel = try c.decode(Double.self, forKey: .skillLevel)
        bingoKnowledge = try c.decodeIfPresent(Double.self, forKey: .bingoKnowledge) ?? 0.10
        board = try c.decode([[SavedTile?]].self, forKey: .board)
        players = try c.decode([SavedPlayer].self, forKey: .players)
        bag = try c.decode([String].self, forKey: .bag)
        isGameOver = try c.decode(Bool.self, forKey: .isGameOver)
        isHumanTurn = try c.decode(Bool.self, forKey: .isHumanTurn)
        scorelessTurns = try c.decodeIfPresent(Int.self, forKey: .scorelessTurns) ?? 0
        turnNumber = try c.decodeIfPresent(Int.self, forKey: .turnNumber) ?? 1
        moveHistory = try c.decode([MoveHistoryEntry].self, forKey: .moveHistory)
    }
}

// MARK: - Game History (finished-game archive)

/// One finished game: a compact summary plus the final-board snapshot. Stored per-user
/// and synced across that user's own devices via iCloud KVS (see GameHistoryStore).
struct GameRecord: Codable, Identifiable {
    enum Result: String, Codable { case won = "Won", lost = "Lost", tied = "Tie" }

    /// Stable per game: the GKTurnBasedMatch matchID for online games (so the same game
    /// dedups across a user's devices), a fresh UUID for AI games.
    let id: String
    let date: Date
    let isOnline: Bool
    let localName: String
    let opponentName: String
    let localScore: Int
    let opponentScore: Int
    /// Row-major final board: '.' = empty, 'A'–'Z' = a tile, 'a'–'z' = a blank played as
    /// that letter. `cols` is the row width for decoding.
    let board: String
    let cols: Int

    var result: Result {
        if localScore > opponentScore { return .won }
        if localScore < opponentScore { return .lost }
        return .tied
    }

    /// Decode the compact board into a grid; nil = empty cell.
    func boardGrid() -> [[(letter: String, isBlank: Bool)?]] {
        guard cols > 0 else { return [] }
        var grid: [[(letter: String, isBlank: Bool)?]] = []
        var row: [(letter: String, isBlank: Bool)?] = []
        for ch in board {
            if ch == "." {
                row.append(nil)
            } else {
                row.append((String(ch).uppercased(), ch.isLowercase))
            }
            if row.count == cols { grid.append(row); row = [] }
        }
        if !row.isEmpty { grid.append(row) }
        return grid
    }

    /// Compact-encode the engine's board model. Empty/"." cells → '.'; blanks → lowercase.
    static func encodeBoard(_ board: [[SquareModel]]) -> String {
        var s = ""
        for row in board {
            for sq in row {
                if let l = sq.letter, !l.isEmpty, l != "." {
                    s += sq.isBlank ? l.lowercased() : l.uppercased()
                } else {
                    s += "."
                }
            }
        }
        return s
    }
}

/// Per-user archive of finished games, persisted in iCloud KVS so it syncs across the
/// user's own devices.
///
/// Storage is ONE KVS KEY PER GAME (`ghRec_<id>` → JSON(GameRecord)), NOT a single shared
/// array. This is deliberate: a shared-array read-modify-write is a distributed
/// last-writer-wins blob, so two of the user's devices archiving around the same time can
/// clobber each other's records (a lost update). Per-record keys are naturally convergent —
/// each device only ever writes its OWN game's key, and the same game id resolves to the
/// same record, so there is no shared blob to lose. Deletes use a tombstone (`ghDel_<id>`)
/// so a delete on one device can't be undone by another device re-syncing the record.
@MainActor
@Observable
final class GameHistoryStore {
    private let kvStore = NSUbiquitousKeyValueStore.default
    private static let recPrefix = "ghRec_"        // one key per game: ghRec_<id> -> JSON(GameRecord)
    private static let delPrefix = "ghDel_"        // delete tombstone: ghDel_<id>
    private static let legacyKey = "gameHistory"   // old single-array key (migrated away on launch)
    private static let maxDisplay = 200            // newest N surfaced in `games`
    private static let maxStored = 400             // hard cap on stored record keys (KVS allows ~1024)

    /// Newest first.
    private(set) var games: [GameRecord] = []

    init() {
        migrateLegacyIfNeeded()
        reload()
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        kvStore.synchronize()
    }

    /// Record a finished game. Idempotent (keyed by id) and convergent across the user's
    /// devices — writes only this game's key, never a shared array.
    func record(_ g: GameRecord) {
        guard let data = try? JSONEncoder().encode(g) else { return }
        // Never resurrect a deliberately-deleted game. A tombstone is cleared ONLY by an
        // explicit undelete — not implicitly here — so no call path (a finished online match
        // re-seen as over, a cross-device re-sync) can re-archive a record the user removed.
        guard kvStore.string(forKey: Self.delPrefix + g.id) == nil else { return }
        kvStore.set(data, forKey: Self.recPrefix + g.id)
        kvStore.synchronize()
        reload()
    }

    /// Whether a game with this id is already archived OR deliberately deleted (used to dedup
    /// online games by matchID). Tombstone-aware: a deleted id reports `true` so the game-over
    /// archiver won't re-create it. Checks storage directly, reliable beyond the display cap.
    func contains(_ id: String) -> Bool {
        kvStore.data(forKey: Self.recPrefix + id) != nil || kvStore.string(forKey: Self.delPrefix + id) != nil
    }

    func delete(_ g: GameRecord) {
        kvStore.set("1", forKey: Self.delPrefix + g.id)       // tombstone so it can't re-sync back
        kvStore.removeObject(forKey: Self.recPrefix + g.id)
        kvStore.synchronize()
        reload()
    }

    func deleteAll() {
        for g in games {
            kvStore.set("1", forKey: Self.delPrefix + g.id)
            kvStore.removeObject(forKey: Self.recPrefix + g.id)
        }
        kvStore.synchronize()
        reload()
    }

    // MARK: - internals

    private func reload() {
        let all = kvStore.dictionaryRepresentation
        let tombstoned = Set(all.keys
            .filter { $0.hasPrefix(Self.delPrefix) }
            .map { String($0.dropFirst(Self.delPrefix.count)) })
        var recs: [GameRecord] = []
        for (k, v) in all where k.hasPrefix(Self.recPrefix) {
            guard let data = v as? Data,
                  let rec = try? JSONDecoder().decode(GameRecord.self, from: data),
                  !tombstoned.contains(rec.id) else { continue }
            recs.append(rec)
        }
        recs.sort { $0.date > $1.date }
        if recs.count > Self.maxStored {
            for g in recs.dropFirst(Self.maxStored) {   // space-prune oldest keys (no tombstone)
                kvStore.removeObject(forKey: Self.recPrefix + g.id)
            }
            recs = Array(recs.prefix(Self.maxStored))
        }
        games = Array(recs.prefix(Self.maxDisplay))
    }

    /// One-time migration off the old single-array `gameHistory` key into per-record keys.
    private func migrateLegacyIfNeeded() {
        guard let data = kvStore.data(forKey: Self.legacyKey),
              let recs = try? JSONDecoder().decode([GameRecord].self, from: data) else { return }
        for r in recs where kvStore.data(forKey: Self.recPrefix + r.id) == nil
            && kvStore.string(forKey: Self.delPrefix + r.id) == nil {   // don't migrate a tombstoned id back
            if let d = try? JSONEncoder().encode(r) { kvStore.set(d, forKey: Self.recPrefix + r.id) }
        }
        kvStore.removeObject(forKey: Self.legacyKey)
        kvStore.synchronize()
    }
}
