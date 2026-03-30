import Foundation
import GameKit
import Observation

@MainActor
@Observable
class GameCenterManager: NSObject, GKLocalPlayerListener {
    var isAuthenticated = false
    var localPlayerID = ""
    var localDisplayName = ""
    var authError: String?
    var currentMatch: GKTurnBasedMatch?
    var isWaitingForOpponent = false

    weak var engine: QuackleEngine?


    func authenticate() {
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.authError = error.localizedDescription
                    self.isAuthenticated = false
                    return
                }
                let player = GKLocalPlayer.local
                self.isAuthenticated = player.isAuthenticated
                if player.isAuthenticated {
                    self.localPlayerID = player.gamePlayerID
                    self.localDisplayName = player.displayName
                    self.authError = nil
                    GKLocalPlayer.local.register(self)
                    // Restore any pending turn data from a previous failed submission
                    if self.pendingTurnData == nil {
                        self.pendingTurnData = UserDefaults.standard.data(forKey: "pendingTurnData")
                    }
                    self.loadActiveMatch()
                }
            }
        }
    }

    // MARK: - Load Active Match (on launch)

    func loadActiveMatch() {
        Task {
            do {
                let best = try await bestPlayableMatch()
                if let best {
                    self.currentMatch = best
                    print("[GameCenter] Found active match on launch: \(best.matchID)")
                    self.retryPendingTurn()
                }
            } catch {
                print("[GameCenter] loadActiveMatch error: \(error.localizedDescription)")
            }
        }
    }

    /// Loads all matches, removes non-playable ones, returns the best playable match (or nil).
    /// Used by both loadActiveMatch and findOrCreateMatch for consistent dedup.
    private func bestPlayableMatch() async throws -> GKTurnBasedMatch? {
        let matches = try await GKTurnBasedMatch.loadMatches()
        print("[GameCenter] Found \(matches.count) existing matches")

        var best: GKTurnBasedMatch?
        for match in matches {
            let hasData = match.matchData != nil && !(match.matchData?.isEmpty ?? true)
            let anyQuit = match.participants.contains { $0.matchOutcome == .quit }
            let playable = (match.status == .open || match.status == .matching)
            print("[GameCenter]   status=\(match.status.rawValue) hasData=\(hasData) anyQuit=\(anyQuit)")

            if !playable || anyQuit {
                print("[GameCenter]   removing non-playable match")
                try? await match.remove()
                continue
            }

            if hasData {
                if let data = match.matchData,
                   let state = try? JSONDecoder().decode(MultiplayerGameState.self, from: data),
                   state.isGameOver {
                    print("[GameCenter]   removing finished match")
                    try? await match.remove()
                    continue
                }
            }

            // Keep the best match. Priority:
            // 1. Has game data (in-progress) beats empty
            // 2. Fully paired (both participants) beats unpaired
            // 3. Smallest matchID as final tiebreak
            if let existing = best {
                let existingHasData = existing.matchData != nil && !(existing.matchData?.isEmpty ?? true)
                let paired = match.participants.allSatisfy { $0.player != nil }
                let existingPaired = existing.participants.allSatisfy { $0.player != nil }

                let preferNew: Bool
                if hasData != existingHasData {
                    preferNew = hasData
                } else if paired != existingPaired {
                    preferNew = paired
                } else {
                    preferNew = match.matchID < existing.matchID
                }
                if preferNew {
                    print("[GameCenter]   removing duplicate \(existing.matchID)")
                    try? await existing.remove()
                    best = match
                } else {
                    print("[GameCenter]   removing duplicate \(match.matchID)")
                    try? await match.remove()
                }
            } else {
                best = match
            }
        }
        return best
    }

    // MARK: - Find or Create Match

    var isFinding = false

    func findOrCreateMatch() {
        guard !isFinding else { return }
        isFinding = true

        Task {
            defer { self.isFinding = false }
            do {
                // 1. Find best existing match (cleans up non-playable/duplicates)
                if let match = try await self.bestPlayableMatch() {
                    print("[GameCenter]   using existing match")
                    self.handleMatchFound(match)
                    return
                }

                // 2. No existing match — auto-match (only two players use this app)
                print("[GameCenter] Creating auto-match...")
                let request = GKMatchRequest()
                request.minPlayers = 2
                request.maxPlayers = 2
                let match = try await GKTurnBasedMatch.find(for: request)
                print("[GameCenter] Auto-match created: \(match.matchID)")
                self.handleMatchFound(match)
            } catch {
                print("[GameCenter] Error: \(error.localizedDescription)")
                self.engine?.errorMessage = "Game Center: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Match Management

    /// Ensures the multiplayer move callback is wired. Called every time we enter
    /// a multiplayer game, so the callback survives game-mode switches.
    private func ensureMultiplayerCallback() {
        guard let engine else { return }
        guard engine.onMultiplayerMoveCommitted == nil else { return }
        print("[GameCenter] Re-wiring onMultiplayerMoveCommitted callback")
        engine.onMultiplayerMoveCommitted = { [weak engine, weak self] in
            guard let engine, let gcm = self else { return }
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
                if localScore == opponentScore {
                    gcm.endMatch(matchData: data, outcome: .tied)
                } else {
                    gcm.endMatch(matchData: data, localWon: localScore > opponentScore)
                }
            } else {
                gcm.submitTurn(matchData: data)
            }
        }
    }

    func handleMatchFound(_ match: GKTurnBasedMatch) {
        currentMatch = match
        lastLoadedDataSize = 0
        ensureMultiplayerCallback()

        let isMyTurn = match.currentParticipant?.player?.gamePlayerID == localPlayerID
        let hasData = match.matchData != nil && !(match.matchData?.isEmpty ?? true)
        print("[GameCenter] Match found: isMyTurn=\(isMyTurn), hasData=\(hasData), participants=\(match.participants.count)")
        for p in match.participants {
            print("[GameCenter]   participant: \(p.player?.displayName ?? "?") id=\(p.player?.gamePlayerID ?? "nil")")
        }
        print("[GameCenter]   currentParticipant: \(match.currentParticipant?.player?.displayName ?? "?")")
        print("[GameCenter]   localPlayerID: \(localPlayerID)")

        if let data = match.matchData, !data.isEmpty {
            do {
                let state = try JSONDecoder().decode(MultiplayerGameState.self, from: data)
                print("[GameCenter] Restoring existing game state")
                self.loadMatchState(state, from: match)
                return
            } catch {
                print("[GameCenter] DECODE FAILED in handleMatchFound: \(error)")
                self.engine?.errorMessage = "Failed to load game state"
                return
            }
        }
        if isMyTurn {
            print("[GameCenter] New match — I go first, initializing game")
            self.startNewMultiplayerGame(from: match)
        } else {
            print("[GameCenter] New match — opponent goes first, waiting")
            self.isWaitingForOpponent = true
            self.engine?.gameMode = .multiplayer
            self.engine?.showModeSelection = false
            // Clear stale state from any previous game so waiting view shows cleanly
            self.engine?.board = []
            self.engine?.rack = []
            self.engine?.availableRack = []
            self.engine?.players = []
            self.engine?.moveHistory = []
            self.engine?.tentativePlacements = []
            self.engine?.isGameOver = false
        }
    }

    private func startNewMultiplayerGame(from match: GKTurnBasedMatch) {
        guard let engine else { return }
        let participants = match.participants
        guard participants.count == 2 else { return }

        let localID = localPlayerID
        let localName = localDisplayName
        var opponentName = "Opponent"
        var opponentID = ""

        for p in participants {
            if let player = p.player, player.gamePlayerID != localID {
                opponentName = player.displayName
                opponentID = player.gamePlayerID
            }
        }

        engine.startMultiplayerGame(
            player1Name: localName,
            player2Name: opponentName,
            localPlayerIndex: 0,
            player1GameCenterID: localID,
            player2GameCenterID: opponentID
        )
    }

    private func loadMatchState(_ state: MultiplayerGameState, from match: GKTurnBasedMatch) {
        guard let engine else { return }

        // Update display names and IDs from resolved match participants
        var s = state
        var matchedPlayer1 = false
        var matchedPlayer2 = false
        for p in match.participants {
            guard let player = p.player else { continue }
            if !matchedPlayer1 && player.gamePlayerID == s.player1GameCenterID {
                matchedPlayer1 = true
                s.player1DisplayName = player.displayName
            } else if !matchedPlayer2 && (player.gamePlayerID == s.player2GameCenterID || s.player2GameCenterID.isEmpty) {
                matchedPlayer2 = true
                s.player2GameCenterID = player.gamePlayerID
                s.player2DisplayName = player.displayName
            }
        }

        let localIndex = (s.player1GameCenterID == localPlayerID) ? 0 : 1
        engine.loadMultiplayerState(s, localPlayerIndex: localIndex)
    }

    /// Pending turn data for retry if submission fails (persisted across app restarts)
    var pendingTurnData: Data? {
        didSet {
            if let data = pendingTurnData {
                UserDefaults.standard.set(data, forKey: "pendingTurnData")
            } else {
                UserDefaults.standard.removeObject(forKey: "pendingTurnData")
            }
        }
    }

    func submitTurn(matchData: Data) {
        guard let match = currentMatch else {
            print("[GameCenter] submitTurn: no current match!")
            return
        }
        let nextParticipants = match.participants.filter {
            $0.player?.gamePlayerID != localPlayerID
        }
        print("[GameCenter] submitTurn: \(matchData.count) bytes, nextParticipants=\(nextParticipants.count)")
        for p in nextParticipants {
            print("[GameCenter]   next: \(p.player?.displayName ?? "?") id=\(p.player?.gamePlayerID ?? "nil") status=\(p.status.rawValue)")
        }
        guard !nextParticipants.isEmpty else {
            print("[GameCenter] submitTurn: no next participants!")
            return
        }

        pendingTurnData = matchData

        Task {
            var lastError: Error?
            for attempt in 1...3 {
                do {
                    // Re-fetch match for retries to get fresh participant state
                    let freshMatch = attempt == 1 ? match : try await GKTurnBasedMatch.load(withID: match.matchID)
                    if attempt > 1 {
                        self.currentMatch = freshMatch
                    }
                    let freshNext = freshMatch.participants.filter {
                        $0.player?.gamePlayerID != self.localPlayerID
                    }
                    guard !freshNext.isEmpty else {
                        print("[GameCenter] submitTurn attempt \(attempt): no next participants")
                        continue
                    }
                    try await freshMatch.endTurn(
                        withNextParticipants: freshNext,
                        turnTimeout: GKTurnTimeoutDefault,
                        match: matchData
                    )
                    print("[GameCenter] submitTurn: SUCCESS (attempt \(attempt))")
                    self.pendingTurnData = nil
                    return
                } catch {
                    lastError = error
                    print("[GameCenter] submitTurn attempt \(attempt): FAILED — \(error.localizedDescription)")
                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                    }
                }
            }
            self.engine?.errorMessage = "Failed to send turn after 3 attempts: \(lastError?.localizedDescription ?? "unknown")"
        }
    }

    /// Retry pending turn submission (called on app foreground)
    func retryPendingTurn() {
        guard let data = pendingTurnData else { return }
        print("[GameCenter] Retrying pending turn submission...")
        submitTurn(matchData: data)
    }

    func endMatch(matchData: Data, localWon: Bool? = nil, outcome: GKTurnBasedMatch.Outcome? = nil) {
        guard let match = currentMatch else { return }
        for p in match.participants {
            if let outcome {
                p.matchOutcome = outcome
            } else if let localWon {
                let isLocal = p.player?.gamePlayerID == localPlayerID
                p.matchOutcome = isLocal == localWon ? .won : .lost
            }
        }
        Task {
            do {
                try await match.endMatchInTurn(withMatch: matchData)
            } catch {
                self.engine?.errorMessage = "Failed to end match: \(error.localizedDescription)"
            }
            self.isWaitingForOpponent = false
        }
    }

    func forfeitMatch() {
        guard let match = currentMatch else { return }

        Task {
            do {
                // Refresh match to get latest participant/turn state
                let fresh = try await GKTurnBasedMatch.load(withID: match.matchID)
                let isMyTurn = fresh.currentParticipant?.player?.gamePlayerID == localPlayerID
                print("[GameCenter] forfeit: isMyTurn=\(isMyTurn), status=\(fresh.status.rawValue)")

                if isMyTurn {
                    let nextParticipants = fresh.participants.filter {
                        $0.player?.gamePlayerID != self.localPlayerID
                    }
                    try await fresh.participantQuitInTurn(
                        with: .quit,
                        nextParticipants: nextParticipants,
                        turnTimeout: GKTurnTimeoutDefault,
                        match: fresh.matchData ?? Data()
                    )
                } else {
                    try await fresh.participantQuitOutOfTurn(with: .quit)
                }
                print("[GameCenter] forfeit: SUCCESS")
                self.currentMatch = nil
                self.pendingTurnData = nil
                self.isWaitingForOpponent = false
                self.engine?.showModeSelection = true
            } catch {
                print("[GameCenter] forfeit FAILED: \(error.localizedDescription)")
                self.engine?.errorMessage = "Failed to forfeit: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Game Switching

    var hasActiveMatch: Bool {
        guard let match = currentMatch else { return false }
        return match.status == .open || match.status == .matching
    }

    func resumeCurrentMatch() {
        guard let match = currentMatch, let engine else { return }

        // Save current AI game before switching
        if engine.gameMode == .ai {
            engine.saveGameState()
        }

        Task {
            do {
                let refreshed = try await GKTurnBasedMatch.load(withID: match.matchID)
                self.currentMatch = refreshed
                self.handleMatchFound(refreshed)
            } catch {
                print("[GameCenter] resumeMatch error: \(error.localizedDescription)")
                engine.errorMessage = "Failed to resume match: \(error.localizedDescription)"
            }
        }
    }

    /// Tracks last-loaded match data size to avoid redundant reloads in poll
    private var lastLoadedDataSize: Int = 0

    // MARK: - Polling

    func pollForMatchUpdate() {
        guard let match = currentMatch else { return }
        Task {
            do {
                // Use loadMatches() instead of load(withID:) to avoid stale cached data
                let matches = try await GKTurnBasedMatch.loadMatches()
                guard let refreshed = matches.first(where: { $0.matchID == match.matchID }) else {
                    print("[GameCenter] poll: match not found in loadMatches() — navigating away")
                    self.isWaitingForOpponent = false
                    self.currentMatch = nil
                    self.pendingTurnData = nil
                    self.engine?.isGameOver = false
                    self.engine?.showModeSelection = true
                    return
                }
                self.currentMatch = refreshed
                let dataSize = refreshed.matchData?.count ?? 0
                let currentTurn = refreshed.currentParticipant?.player?.gamePlayerID ?? "nil"
                print("[GameCenter] poll: dataSize=\(dataSize), currentTurn=\(currentTurn), local=\(self.localPlayerID), waiting=\(self.isWaitingForOpponent), status=\(refreshed.status.rawValue)")

                // Check if match ended (opponent forfeited or match otherwise closed)
                if refreshed.status != .open && refreshed.status != .matching {
                    print("[GameCenter] poll: match is no longer open (status=\(refreshed.status.rawValue))")
                    self.handleMatchEnded(refreshed)
                    return
                }

                // Check if opponent quit (participant outcome)
                let opponentQuit = refreshed.participants.contains { p in
                    p.player?.gamePlayerID != self.localPlayerID && p.matchOutcome == .quit
                }
                if opponentQuit {
                    print("[GameCenter] poll: opponent has quit")
                    self.handleMatchEnded(refreshed)
                    return
                }

                guard let data = refreshed.matchData, !data.isEmpty else {
                    print("[GameCenter] poll: no match data yet")
                    return
                }

                // Skip if data hasn't changed since last load
                if data.count == self.lastLoadedDataSize && !self.isWaitingForOpponent {
                    return
                }

                let state: MultiplayerGameState
                do {
                    state = try JSONDecoder().decode(MultiplayerGameState.self, from: data)
                } catch {
                    print("[GameCenter] poll: DECODE FAILED — \(error)")
                    return
                }

                // Waiting player: opponent made first move
                if self.isWaitingForOpponent {
                    print("[GameCenter] poll: got match data while waiting, loading state")
                    self.isWaitingForOpponent = false
                    self.lastLoadedDataSize = data.count
                    self.loadMatchState(state, from: refreshed)
                    return
                }
                // Non-active player: check if opponent has moved (currentPlayerIndex changed)
                let localIndex = (state.player1GameCenterID == self.localPlayerID) ? 0 : 1
                if state.currentPlayerIndex == localIndex {
                    print("[GameCenter] poll: it's now our turn, loading state")
                    self.lastLoadedDataSize = data.count
                    self.loadMatchState(state, from: refreshed)
                }
            } catch {
                print("[GameCenter] poll error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - GKTurnBasedEventListener

    nonisolated func player(_ player: GKPlayer, receivedTurnEventFor match: GKTurnBasedMatch, didBecomeActive: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let hasData = match.matchData != nil && !(match.matchData?.isEmpty ?? true)
            print("[GameCenter] receivedTurnEvent: didBecomeActive=\(didBecomeActive), hasData=\(hasData), dataSize=\(match.matchData?.count ?? 0)")
            self.currentMatch = match

            // If not in multiplayer mode (e.g., playing AI), just update match reference silently
            guard self.engine?.gameMode == .multiplayer || self.isWaitingForOpponent else {
                print("[GameCenter] receivedTurnEvent: not in multiplayer mode, updating match reference only")
                return
            }

            if let data = match.matchData, !data.isEmpty {
                do {
                    let state = try JSONDecoder().decode(MultiplayerGameState.self, from: data)
                    print("[GameCenter] receivedTurnEvent: decoded state, currentPlayer=\(state.currentPlayerIndex)")
                    self.isWaitingForOpponent = false
                    self.loadMatchState(state, from: match)
                } catch {
                    print("[GameCenter] receivedTurnEvent: DECODE FAILED — \(error)")
                }
            } else {
                print("[GameCenter] receivedTurnEvent: no match data, ignoring")
            }
        }
    }

    nonisolated func player(_ player: GKPlayer, matchEnded match: GKTurnBasedMatch) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            print("[GameCenter] matchEnded callback, status=\(match.status.rawValue)")
            self.currentMatch = match
            guard self.engine?.gameMode == .multiplayer || self.isWaitingForOpponent else { return }
            self.handleMatchEnded(match)
        }
    }

    // MARK: - Match End Handling

    private func handleMatchEnded(_ match: GKTurnBasedMatch) {
        // Determine what happened
        let opponentQuit = match.participants.contains { p in
            p.player?.gamePlayerID != self.localPlayerID && p.matchOutcome == .quit
        }
        let opponentName = match.participants.first { p in
            p.player?.gamePlayerID != self.localPlayerID
        }?.player?.displayName ?? "Opponent"

        if opponentQuit {
            print("[GameCenter] opponent \(opponentName) forfeited")
            self.engine?.errorMessage = "\(opponentName) forfeited the game"
        } else {
            print("[GameCenter] match ended (status=\(match.status.rawValue))")
        }

        self.isWaitingForOpponent = false
        self.currentMatch = nil
        self.pendingTurnData = nil
        // Go straight to mode selection so the user isn't stuck on a dead game board
        self.engine?.isGameOver = false
        self.engine?.showModeSelection = true
    }
}
