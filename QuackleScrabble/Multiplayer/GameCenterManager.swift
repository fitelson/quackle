import Foundation
import GameKit
import Observation
#if os(iOS)
import UIKit
#endif

/// The local player's outcome for a terminal (game-ending) submission.
private enum TerminalOutcome: Int, Codable {
    case won, lost, tied
}

private struct PendingTurn: Codable {
    let matchID: String
    let data: Data
    /// nil = a normal mid-game turn (endTurn). Non-nil = a terminal end-match
    /// submission (endMatchInTurn) carrying the local player's outcome, so a
    /// transient failure can be retried instead of losing the game-deciding move.
    var terminal: TerminalOutcome?

    init(matchID: String, data: Data, terminal: TerminalOutcome? = nil) {
        self.matchID = matchID
        self.data = data
        self.terminal = terminal
    }

    enum CodingKeys: String, CodingKey { case matchID, data, terminal }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        matchID = try c.decode(String.self, forKey: .matchID)
        data = try c.decode(Data.self, forKey: .data)
        terminal = try c.decodeIfPresent(TerminalOutcome.self, forKey: .terminal)
    }
}

private enum FamilyMultiplayer {
    static let fitelsonID = "A:_efcfe63bc31fd01cf29ea407c71d780a"
    static let szwarchID = "A:_ead7114711f507e29d1cf28ac791cfa7"
    static let allowedIDs: Set<String> = [fitelsonID, szwarchID]

    static func isAllowed(_ playerID: String) -> Bool {
        allowedIDs.contains(playerID)
    }

    static func opponentID(for localPlayerID: String) -> String? {
        switch localPlayerID {
        case fitelsonID: return szwarchID
        case szwarchID: return fitelsonID
        default: return nil
        }
    }

    /// EITHER account may create/initiate a game. The "owner" is only the deterministic
    /// tiebreak KEEPER — the lexicographically-smaller gamePlayerID. If both happen to
    /// create a seat in a true-simultaneous race, the owner keeps its seat and the
    /// non-owner yields and joins it, so the two always converge on one game. Decided
    /// purely from the local ID (zero coordination).
    static let ownerID = allowedIDs.min() ?? fitelsonID
    static func isOwner(_ playerID: String) -> Bool { playerID == ownerID }

    static func displayName(for playerID: String) -> String {
        switch playerID {
        case fitelsonID: return "fitelson"
        case szwarchID: return "Szwarch Of River Twilight"
        default: return "Opponent"
        }
    }
}

private enum FamilyMultiplayerError: LocalizedError {
    case unauthorizedAccount
    case unexpectedParticipants

    var errorDescription: String? {
        switch self {
        case .unauthorizedAccount:
            return "Online play is restricted to the two configured Game Center accounts."
        case .unexpectedParticipants:
            return "This online match has unexpected Game Center participants."
        }
    }
}

@MainActor
@Observable
class GameCenterManager: NSObject, GKLocalPlayerListener {
    var isAuthenticated = false
    var localPlayerID = ""
    var localDisplayName = ""
    var authError: String?
    var currentMatch: GKTurnBasedMatch?
    var isWaitingForOpponent = false

    var canUseMultiplayer: Bool {
        isAuthenticated && FamilyMultiplayer.isAllowed(localPlayerID)
    }

    /// Whether this device's account is the tiebreak "owner"/keeper (see
    /// FamilyMultiplayer.ownerID). Either account can initiate; the owner just keeps its
    /// seat when a simultaneous double-create needs to collapse to one game.
    private var localIsOwner: Bool { FamilyMultiplayer.isOwner(localPlayerID) }

    weak var engine: QuackleEngine?

    /// iCloud key-value store for sharing active match ID across devices
    private let kvStore = NSUbiquitousKeyValueStore.default
    private static let kActiveMatchID = "activeMatchID"

    /// The active match ID, synced across devices via iCloud KVS
    var sharedActiveMatchID: String? {
        get { kvStore.string(forKey: Self.kActiveMatchID) }
        set {
            if let newValue {
                kvStore.set(newValue, forKey: Self.kActiveMatchID)
            } else {
                kvStore.removeObject(forKey: Self.kActiveMatchID)
            }
            kvStore.synchronize()
            print("[GameCenter] Shared match ID → \(newValue ?? "nil")")
        }
    }

    func authenticate() {
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // GameKit needs to present its sign-in UI — present it instead of
                // silently dropping it (which left the user stuck on "Signing in…").
                if let viewController {
                    #if os(iOS)
                    let scene = UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }
                        .first { $0.activationState == .foregroundActive }
                    if let root = scene?.keyWindow?.rootViewController {
                        root.present(viewController, animated: true)
                    } else {
                        self.authError = "Sign in to Game Center in Settings to play online."
                        self.isAuthenticated = false
                    }
                    #else
                    self.authError = "Sign in to Game Center via System Settings to play online."
                    self.isAuthenticated = false
                    #endif
                    return
                }
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
                    self.authError = self.canUseMultiplayer ? nil : FamilyMultiplayerError.unauthorizedAccount.localizedDescription
                    GKLocalPlayer.local.register(self)
                    // (No friends-list usage: matchmaking is auto-match, not direct invite.)
                    // Restore any pending turn data from a previous failed submission
                    if self.pendingTurn == nil {
                        self.pendingTurn = self.loadPendingTurn()
                    }
                    if self.canUseMultiplayer {
                        self.loadActiveMatch()
                    }
                } else {
                    // Completed unauthenticated with no controller/error — don't
                    // leave the UI stuck on "Signing into Game Center…".
                    self.authError = "Not signed in to Game Center. Sign in to play online."
                }
            }
        }
    }

    // MARK: - Load Active Match (on launch)

    func loadActiveMatch() {
        guard canUseMultiplayer else { return }
        Task {
            do {
                // One-time recovery from the accumulated stale-match mess (no-op after first run).
                await self.resetStaleMatchesOnce()
                // Try to load the shared match ID from iCloud KVS
                kvStore.synchronize()
                if let matchID = sharedActiveMatchID {
                    print("[GameCenter] iCloud KVS has active match: \(matchID)")
                    do {
                        let match = try await GKTurnBasedMatch.load(withID: matchID)
                        let playable = (match.status == .open || match.status == .matching)
                        let anyQuit = match.participants.contains { $0.matchOutcome == .quit }
                        // Only adopt a match that's actually a shared game (paired or has
                        // data). An unpaired/empty seat in KVS is the stale-pointer bug —
                        // clear it and fall through so we re-run matchmaking.
                        if playable && !anyQuit && isAllowedMatch(match) && isPairedOrHasData(match) {
                            self.currentMatch = match
                            print("[GameCenter] Loaded shared match on launch: \(matchID)")
                            self.retryPendingTurn()
                            return
                        } else {
                            print("[GameCenter] Shared match not a live shared game (unpaired/finished), clearing")
                            self.sharedActiveMatchID = nil
                        }
                    } catch {
                        print("[GameCenter] Could not load shared match \(matchID): \(error.localizedDescription)")
                        self.sharedActiveMatchID = nil
                    }
                }

                // Fallback: scan all matches
                let best = try await bestPlayableMatch()
                if let best {
                    self.currentMatch = best
                    self.sharedActiveMatchID = best.matchID
                    print("[GameCenter] Found active match on launch: \(best.matchID)")
                    self.retryPendingTurn()
                }
            } catch {
                print("[GameCenter] loadActiveMatch error: \(error.localizedDescription)")
            }
        }
    }

    /// A match worth persisting in iCloud KVS / adopting as the shared game: it has game
    /// data OR both configured players are resolved participants. A FRESH unpaired
    /// auto-match seat (opponent slot still nil, no data) is NEITHER — persisting one is
    /// the bug that locked each device to its own opponent-less game (the "three games").
    private func isPairedOrHasData(_ m: GKTurnBasedMatch) -> Bool {
        if let d = m.matchData, !d.isEmpty { return true }
        let resolved = Set(m.participants.compactMap { $0.player?.gamePlayerID })
        return m.participants.count >= 2
            && m.participants.allSatisfy { $0.player != nil }
            && resolved == FamilyMultiplayer.allowedIDs
    }

    /// GUEST-only: remove the local player's own UNPAIRED, no-data seeking matches so the
    /// next find(for:) joins the HOST's open seat instead of returning the guest's own
    /// orphan. Safe ONLY under the host/guest asymmetry — the host never auto-matches into
    /// the guest's seat, so removing it can't cancel a pairing the host is mid-join on.
    /// Once the host HAS joined (match becomes paired), it's skipped here and kept.
    /// remove() is local-only.
    private func removeOwnUnpairedMatches() async {
        guard let matches = try? await GKTurnBasedMatch.loadMatches() else { return }
        for m in matches {
            let hasData = m.matchData.map { !$0.isEmpty } ?? false
            let paired = m.participants.allSatisfy { $0.player != nil }
            let playable = (m.status == .open || m.status == .matching)
            if playable && !paired && !hasData {
                print("[GameCenter] Guest removing own unpaired seat \(m.matchID)")
                try? await m.remove()
            }
        }
    }

    /// ONE-TIME (per device, per reset-version) cleanup to recover from the accumulated
    /// "three games" mess: remove every match that is NOT a live shared game — abandoned
    /// unpaired seats (no opponent, no data), ended matches, and quit matches. KEEPS any
    /// real paired/has-data game in progress. Then clear the stale KVS pointer. Guarded by
    /// a UserDefaults flag so it runs only once and can't disrupt future live pairings.
    private func resetStaleMatchesOnce() async {
        let key = "didResetStaleMatches_v2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        if let matches = try? await GKTurnBasedMatch.loadMatches() {
            for m in matches {
                let ended = m.status == .ended
                let anyQuit = m.participants.contains { $0.matchOutcome == .quit }
                if !isPairedOrHasData(m) || ended || anyQuit {
                    print("[GameCenter] one-time reset: removing stale match \(m.matchID)")
                    try? await m.remove()
                }
            }
        }
        sharedActiveMatchID = nil
        UserDefaults.standard.set(true, forKey: key)
        print("[GameCenter] one-time stale-match reset complete")
    }

    /// The local player's single canonical open seat. Returns its own playable, allowed,
    /// UNPAIRED, no-data seat (deterministically the smallest matchID) and REMOVES any
    /// extras, so (a) repeated taps reuse one seat instead of opening new ones, (b) the
    /// player's OTHER devices — same Apple ID, same matches in loadMatches() — converge on
    /// the same seat, and (c) there is exactly ONE seat for the opponent to auto-match into.
    /// Returns nil if there's no open seat yet (caller then creates one). Removing extra
    /// UNPAIRED seats is safe: they hold no opponent, so a peer mid-joining a removed one
    /// simply retries onto the survivor.
    private func ownerCanonicalSeat() async -> GKTurnBasedMatch? {
        guard let matches = try? await GKTurnBasedMatch.loadMatches() else { return nil }
        let seats = matches.filter { m in
            let hasData = m.matchData.map { !$0.isEmpty } ?? false
            let paired = m.participants.allSatisfy { $0.player != nil }
            let playable = (m.status == .open || m.status == .matching)
            let anyQuit = m.participants.contains { $0.matchOutcome == .quit }
            return playable && !anyQuit && !paired && !hasData && isAllowedMatch(m)
        }.sorted { $0.matchID < $1.matchID }
        guard let canonical = seats.first else { return nil }
        for extra in seats.dropFirst() {
            print("[GameCenter] Host consolidating: removing extra seat \(extra.matchID)")
            try? await extra.remove()
        }
        return canonical
    }

    /// Loads all matches and returns the best playable match (or nil).
    /// Used by both loadActiveMatch and findOrCreateMatch for consistent selection.
    private func bestPlayableMatch() async throws -> GKTurnBasedMatch? {
        let matches = try await GKTurnBasedMatch.loadMatches()
        print("[GameCenter] Found \(matches.count) existing matches")

        var best: GKTurnBasedMatch?
        for match in matches {
            let hasData = match.matchData != nil && !(match.matchData?.isEmpty ?? true)
            let anyQuit = match.participants.contains { $0.matchOutcome == .quit }
            let playable = (match.status == .open || match.status == .matching)
            print("[GameCenter]   status=\(match.status.rawValue) hasData=\(hasData) anyQuit=\(anyQuit)")

            if !playable || anyQuit || !isAllowedMatch(match) {
                continue
            }

            if hasData {
                if let data = match.matchData,
                   let state = try? JSONDecoder().decode(MultiplayerGameState.self, from: data),
                   state.isGameOver {
                    continue
                }
            }

            let fullyPaired = match.participants.allSatisfy { $0.player != nil }
            if !fullyPaired && !hasData {
                continue
            }

            if best == nil || isBetterPlayableMatch(match, than: best!) {
                best = match
            }
        }
        return best
    }

    private func isBetterPlayableMatch(_ candidate: GKTurnBasedMatch, than existing: GKTurnBasedMatch) -> Bool {
        let candidateHasData = candidate.matchData != nil && !(candidate.matchData?.isEmpty ?? true)
        let existingHasData = existing.matchData != nil && !(existing.matchData?.isEmpty ?? true)
        if candidateHasData != existingHasData { return candidateHasData }

        let candidatePaired = candidate.participants.allSatisfy { $0.player != nil }
        let existingPaired = existing.participants.allSatisfy { $0.player != nil }
        if candidatePaired != existingPaired { return candidatePaired }

        return candidate.matchID < existing.matchID
    }

    private func isAllowedMatch(_ match: GKTurnBasedMatch) -> Bool {
        let resolvedIDs = Set(match.participants.compactMap { $0.player?.gamePlayerID })
        guard resolvedIDs.isSubset(of: FamilyMultiplayer.allowedIDs) else {
            return false
        }

        if let data = match.matchData, !data.isEmpty,
           let state = try? JSONDecoder().decode(MultiplayerGameState.self, from: data) {
            return isAllowedState(state, resolvedIDs: resolvedIDs)
        }

        let fullyPaired = match.participants.allSatisfy { $0.player != nil }
        if fullyPaired {
            return resolvedIDs == FamilyMultiplayer.allowedIDs
        }

        return resolvedIDs.contains(localPlayerID)
    }

    private func isAllowedState(_ state: MultiplayerGameState, resolvedIDs: Set<String> = []) -> Bool {
        let stateIDs = Set([state.player1GameCenterID, state.player2GameCenterID].filter { !$0.isEmpty })
        let knownIDs = stateIDs.union(resolvedIDs)
        return knownIDs == FamilyMultiplayer.allowedIDs && knownIDs.contains(localPlayerID)
    }

    // MARK: - Find or Create Match

    var isFinding = false

    func findOrCreateMatch() {
        guard canUseMultiplayer else {
            engine?.errorMessage = FamilyMultiplayerError.unauthorizedAccount.localizedDescription
            return
        }
        guard !isFinding else { return }
        isFinding = true

        Task {
            defer { self.isFinding = false }
            do {
                // 1. Check iCloud KVS for a shared match (same-user cross-device sync).
                // Adopt ONLY a real shared game (paired or has data) — never a fresh
                // unpaired seat, or each device gets re-stuck on its own empty match.
                kvStore.synchronize()
                if let matchID = sharedActiveMatchID {
                    print("[GameCenter] Checking shared match \(matchID)...")
                    do {
                        let match = try await GKTurnBasedMatch.load(withID: matchID)
                        let playable = (match.status == .open || match.status == .matching)
                        let anyQuit = match.participants.contains { $0.matchOutcome == .quit }
                        if playable && !anyQuit && self.isAllowedMatch(match) && self.isPairedOrHasData(match) {
                            print("[GameCenter]   using shared match from iCloud KVS")
                            self.handleMatchFound(match)
                            return
                        }
                        print("[GameCenter]   shared match not a live shared game; clearing KVS")
                        self.sharedActiveMatchID = nil
                    } catch {
                        print("[GameCenter]   shared match not loadable: \(error.localizedDescription)")
                        self.sharedActiveMatchID = nil
                    }
                }

                // 2. Reuse an existing PAIRED/has-data match if one exists (bestPlayableMatch
                // already skips unpaired+no-data seats). handleMatchFound writes KVS (gated).
                if let match = try await self.bestPlayableMatch() {
                    print("[GameCenter]   using existing match")
                    self.handleMatchFound(match)
                    return
                }

                // 3. No shared game yet — EITHER of us may create/initiate. Both call
                // find(for:), which JOINS the opponent's open seat if one exists, else creates
                // a new one (so the second tapper joins the first's seat). The OWNER reuses
                // its single canonical seat so it never piles up duplicates; the NON-OWNER
                // first drops its own stale empty seats so find() prefers joining the owner's.
                if self.localIsOwner {
                    if let seat = await self.ownerCanonicalSeat() {
                        print("[GameCenter] Owner: reusing canonical seat \(seat.matchID)")
                        self.handleMatchFound(seat)
                        return
                    }
                    print("[GameCenter] Owner: creating/joining via auto-match...")
                } else {
                    await self.removeOwnUnpairedMatches()
                    print("[GameCenter] Non-owner: creating/joining via auto-match...")
                }
                let request = GKMatchRequest()
                request.minPlayers = 2
                request.maxPlayers = 2
                let match = try await GKTurnBasedMatch.find(for: request)
                guard self.isAllowedMatch(match) else {
                    throw FamilyMultiplayerError.unexpectedParticipants
                }
                print("[GameCenter] find(for:) returned \(match.matchID) paired/hasData=\(self.isPairedOrHasData(match))")
                // handleMatchFound: whoever created a fresh seat initializes it and goes
                // first; a joiner waits for the opponent's first move. Convergence is
                // non-destructive: the common case (one starts, the other joins later, or one
                // taps slightly first) is handled by find() JOINING the opponent's open seat.
                // We do NOT auto-yield/destroy a seat after the fact — a non-owner can't even
                // see the owner's unpaired seat (not a participant), and removing a live seat
                // would wipe an in-progress opening move. A true sub-second simultaneous
                // double-create that also slips past GameKit's own dedup is rare and resolves
                // when either player next taps Play Online (find() then joins the other's seat,
                // or the owner reuses its canonical seat).
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
        print("[GameCenter] Wiring onMultiplayerMoveCommitted callback")
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
                    engine.gameResultMessage = "Tie game."
                    gcm.endMatch(matchData: data, outcome: .tied)
                } else {
                    let won = localScore > opponentScore
                    engine.gameResultMessage = won ? "You won!" : "You lost."
                    gcm.endMatch(matchData: data, localWon: won)
                }
            } else {
                gcm.submitTurn(matchData: data)
            }
        }
    }

    func handleMatchFound(_ match: GKTurnBasedMatch) {
        guard isAllowedMatch(match) else {
            print("[GameCenter] Ignoring match with unexpected participants: \(match.matchID)")
            if sharedActiveMatchID == match.matchID {
                sharedActiveMatchID = nil
            }
            engine?.errorMessage = FamilyMultiplayerError.unexpectedParticipants.localizedDescription
            return
        }

        currentMatch = match
        lastLoadedData = nil
        // Only persist a real shared game to KVS — never a fresh unpaired seat (that was
        // the bug that made each device resume its own opponent-less match forever).
        if isPairedOrHasData(match) { sharedActiveMatchID = match.matchID }
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
        // EITHER player may initiate: whoever is the current participant of a fresh seat
        // (the creator) initializes the game and goes first; a joiner (isMyTurn == false)
        // waits for the opponent's first move. Convergence is by find() joining the
        // opponent's open seat at tap time — no after-the-fact seat destruction.
        if isMyTurn {
            print("[GameCenter] New match — I go first, initializing game")
            self.startNewMultiplayerGame(from: match)
        } else {
            print("[GameCenter] Waiting (opponent's turn, or guest awaiting host's match)")
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
        let expectedOpponentID = FamilyMultiplayer.opponentID(for: localID) ?? ""
        var opponentName = FamilyMultiplayer.displayName(for: expectedOpponentID)
        var opponentID = expectedOpponentID

        for p in participants {
            if let player = p.player, player.gamePlayerID == expectedOpponentID {
                opponentName = player.displayName
                opponentID = player.gamePlayerID
            }
        }

        engine.startMultiplayerGame(
            player1Name: localName,
            player2Name: opponentName,
            localPlayerIndex: 0,
            player1GameCenterID: localID,
            player2GameCenterID: opponentID,
            matchID: match.matchID
        )
    }

    private func loadMatchState(_ state: MultiplayerGameState, from match: GKTurnBasedMatch, persistKVS: Bool = true) {
        guard let engine else { return }
        guard isAllowedState(state, resolvedIDs: Set(match.participants.compactMap { $0.player?.gamePlayerID })) else {
            engine.errorMessage = FamilyMultiplayerError.unexpectedParticipants.localizedDescription
            return
        }

        // Update display names and IDs from resolved match participants.
        // Two-pass so an empty stored player2 ID can't steal player1's participant:
        // pass 1 binds exact ID matches; pass 2 fills a still-empty player2 slot from
        // the single remaining unassigned participant.
        var s = state
        let resolved = match.participants.compactMap { $0.player }
        var usedIDs = Set<String>()
        // Pass 1: exact matches.
        for player in resolved {
            if player.gamePlayerID == s.player1GameCenterID {
                s.player1DisplayName = player.displayName
                usedIDs.insert(player.gamePlayerID)
            } else if !s.player2GameCenterID.isEmpty && player.gamePlayerID == s.player2GameCenterID {
                s.player2DisplayName = player.displayName
                usedIDs.insert(player.gamePlayerID)
            }
        }
        // Pass 2: fill an empty player2 from the one leftover participant.
        if s.player2GameCenterID.isEmpty {
            if let leftover = resolved.first(where: { !usedIDs.contains($0.gamePlayerID) && $0.gamePlayerID != s.player1GameCenterID }) {
                s.player2GameCenterID = leftover.gamePlayerID
                s.player2DisplayName = leftover.displayName
            }
        }

        guard s.player1GameCenterID == localPlayerID || s.player2GameCenterID == localPlayerID else {
            engine.errorMessage = FamilyMultiplayerError.unexpectedParticipants.localizedDescription
            return
        }

        let localIndex = (s.player1GameCenterID == localPlayerID) ? 0 : 1
        engine.loadMultiplayerState(s, localPlayerIndex: localIndex, matchID: match.matchID)
        // Record what we just loaded so the poll doesn't reload identical data.
        // Centralized here so EVERY load path (handleMatchFound, poll, turn event)
        // keeps lastLoadedData in sync — otherwise a poll can reload stale
        // pre-commit data over an in-flight local move.
        lastLoadedData = match.matchData
        // This is unambiguously THE shared game (both players known, local is a
        // participant, has data). Persist its ID in iCloud KVS from EVERY live load path so
        // all of this user's devices (same Apple ID) converge on the one same match —
        // including when the opponent first joins our previously-unpaired seat. Skipped on
        // the game-over render path (handleMatchEnded clears KVS right after).
        if persistKVS { sharedActiveMatchID = match.matchID }
    }

    /// Pending turn data for retry if submission fails (persisted across app restarts)
    private var pendingTurn: PendingTurn? {
        didSet {
            if let pendingTurn, let data = try? JSONEncoder().encode(pendingTurn) {
                UserDefaults.standard.set(data, forKey: "pendingTurn")
            } else {
                UserDefaults.standard.removeObject(forKey: "pendingTurn")
                UserDefaults.standard.removeObject(forKey: "pendingTurnData")
            }
        }
    }

    private func loadPendingTurn() -> PendingTurn? {
        if let data = UserDefaults.standard.data(forKey: "pendingTurn"),
           let pendingTurn = try? JSONDecoder().decode(PendingTurn.self, from: data) {
            return pendingTurn
        }
        return nil
    }

    /// True while a submitTurn/runTerminalEnd network Task is in flight, so a
    /// concurrent retry (poll nudge or scenePhase foreground) can't launch a
    /// duplicate submission racing the same pendingTurn.
    private var isSubmitting = false

    func submitTurn(matchData: Data) {
        guard let match = currentMatch else {
            print("[GameCenter] submitTurn: no current match!")
            return
        }
        guard isAllowedMatch(match) else {
            engine?.errorMessage = FamilyMultiplayerError.unexpectedParticipants.localizedDescription
            return
        }
        // Persist the move FIRST so it survives an early return / app restart and
        // gets retried — never drop a committed move before the retry net exists.
        pendingTurn = PendingTurn(matchID: match.matchID, data: matchData)

        // Next participant(s) = everyone except the local player. This INCLUDES an
        // unresolved auto-match slot (player == nil) so the OPENING move can be passed
        // to the not-yet-joined opponent; isAllowedMatch already guarantees no stranger
        // is in the match. (Filtering by the resolved opponent ID would make the first
        // move un-sendable until the opponent's GKPlayer resolves.)
        let nextParticipants = match.participants.filter {
            $0.player?.gamePlayerID != localPlayerID
        }
        print("[GameCenter] submitTurn: \(matchData.count) bytes, nextParticipants=\(nextParticipants.count)")
        for p in nextParticipants {
            print("[GameCenter]   next: \(p.player?.displayName ?? "?") id=\(p.player?.gamePlayerID ?? "nil") status=\(p.status.rawValue)")
        }
        guard !nextParticipants.isEmpty else {
            // Opponent participant not resolved yet (e.g. first move of an unaccepted
            // invite). The move is saved in pendingTurn and will retry automatically.
            print("[GameCenter] submitTurn: no resolved opponent participant yet — move queued for retry")
            engine?.errorMessage = "Opponent isn't ready yet — your move is saved and will send automatically."
            return
        }

        isSubmitting = true
        Task {
            defer { self.isSubmitting = false }
            var lastError: Error?
            for attempt in 1...3 {
                do {
                    // Re-fetch match for retries to get fresh participant state
                    let freshMatch = attempt == 1 ? match : try await GKTurnBasedMatch.load(withID: match.matchID)
                    // Only adopt the refreshed match as current if it's still the active
                    // game — the user may have switched matches during the backoff.
                    if attempt > 1, self.currentMatch == nil || self.currentMatch?.matchID == freshMatch.matchID {
                        self.currentMatch = freshMatch
                    }
                    if freshMatch.currentParticipant?.player?.gamePlayerID != self.localPlayerID {
                        print("[GameCenter] submitTurn attempt \(attempt): turn already advanced; clearing pending turn")
                        self.pendingTurn = nil
                        return
                    }
                    guard self.isAllowedMatch(freshMatch) else {
                        throw FamilyMultiplayerError.unexpectedParticipants
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
                    self.pendingTurn = nil
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

    /// Retry pending turn submission (called on app foreground and nudged by the poll).
    func retryPendingTurn() {
        guard let pendingTurn else { return }
        // A submission is already running — don't launch a duplicate racing the same move.
        guard !isSubmitting else { return }
        // Transient !canUseMultiplayer (e.g. a Game Center sign-out blip) must NOT drop
        // the queued move — keep it and retry once we're authorized again.
        guard canUseMultiplayer else {
            print("[GameCenter] retryPendingTurn: not authorized right now — keeping pending move")
            return
        }
        // Only retry the pending move for the match we're actually in (or none) — don't
        // pull a non-active match into the engine.
        guard currentMatch == nil || currentMatch?.matchID == pendingTurn.matchID else {
            print("[GameCenter] retryPendingTurn: pending is for a non-active match; deferring")
            return
        }
        print("[GameCenter] Retrying pending turn submission for \(pendingTurn.matchID)...")
        Task {
            do {
                let match = try await GKTurnBasedMatch.load(withID: pendingTurn.matchID)
                guard self.isAllowedMatch(match) else {
                    print("[GameCenter] pending turn match has unexpected participants; clearing")
                    self.pendingTurn = nil
                    return
                }
                self.currentMatch = match
                if let terminal = pendingTurn.terminal {
                    // Terminal end: the ONLY success is status == .ended. If the turn
                    // advanced but the match is still open, the end didn't land — keep
                    // the pending so it retries; do NOT drop the outcome.
                    if match.status == .ended {
                        print("[GameCenter] pending terminal already applied (match ended); clearing")
                        self.pendingTurn = nil
                        self.sharedActiveMatchID = nil
                    } else if match.currentParticipant?.player?.gamePlayerID == self.localPlayerID {
                        self.runTerminalEnd(matchData: pendingTurn.data, terminal: terminal)
                    } else {
                        print("[GameCenter] pending terminal: turn advanced but match still open — keeping for retry")
                    }
                    return
                }
                // Non-terminal turn: if the turn already advanced, our move landed.
                if match.currentParticipant?.player?.gamePlayerID != self.localPlayerID {
                    print("[GameCenter] pending turn already submitted or no longer local turn; clearing")
                    self.pendingTurn = nil
                    return
                }
                self.submitTurn(matchData: pendingTurn.data)
            } catch {
                print("[GameCenter] retryPendingTurn failed: \(error.localizedDescription)")
            }
        }
    }

    func endMatch(matchData: Data, localWon: Bool? = nil, outcome: GKTurnBasedMatch.Outcome? = nil) {
        let terminal: TerminalOutcome
        if outcome == .tied {
            terminal = .tied
        } else if let localWon {
            terminal = localWon ? .won : .lost
        } else {
            terminal = .tied
        }
        runTerminalEnd(matchData: matchData, terminal: terminal)
    }

    /// Persist a terminal end-match submission *before* the network call and retry
    /// it (mirrors submitTurn) so a transient failure cannot permanently lose the
    /// game-deciding move. Clears state only on confirmed success.
    private func runTerminalEnd(matchData: Data, terminal: TerminalOutcome) {
        guard let match = currentMatch else { return }
        guard isAllowedMatch(match) else {
            engine?.errorMessage = FamilyMultiplayerError.unexpectedParticipants.localizedDescription
            return
        }
        pendingTurn = PendingTurn(matchID: match.matchID, data: matchData, terminal: terminal)

        isSubmitting = true
        Task {
            defer { self.isSubmitting = false }
            var lastError: Error?
            for attempt in 1...3 {
                do {
                    let fresh = attempt == 1 ? match : try await GKTurnBasedMatch.load(withID: match.matchID)
                    // Only adopt the refreshed match as current if it's still the active
                    // game (the user may have switched away during the backoff).
                    if self.currentMatch == nil || self.currentMatch?.matchID == fresh.matchID {
                        self.currentMatch = fresh
                    }
                    guard self.isAllowedMatch(fresh) else {
                        throw FamilyMultiplayerError.unexpectedParticipants
                    }
                    // Already ended (a prior attempt or the opponent ended it) → success.
                    if fresh.status == .ended {
                        print("[GameCenter] endMatch: already ended; treating as success")
                        self.finishTerminalSuccess()
                        return
                    }
                    // Must be our turn to end in-turn. If the turn advanced while the
                    // match is still open (e.g. opponent timeout) our terminal end did
                    // NOT land — do NOT treat this as success (that would strand the
                    // opponent on a never-ended match with no outcomes written). Keep
                    // pendingTurn/currentMatch and surface the anomaly; a later
                    // retryPendingTurn (or the opponent's own end) resolves it.
                    guard fresh.currentParticipant?.player?.gamePlayerID == self.localPlayerID else {
                        print("[GameCenter] endMatch attempt \(attempt): turn advanced but match still open — keeping pending terminal")
                        self.engine?.errorMessage = "Couldn't finalize the game end yet — it will retry."
                        return
                    }
                    self.applyOutcomes(terminal, to: fresh)
                    try await fresh.endMatchInTurn(withMatch: matchData)
                    print("[GameCenter] endMatch: SUCCESS (attempt \(attempt))")
                    self.finishTerminalSuccess()
                    return
                } catch {
                    lastError = error
                    print("[GameCenter] endMatch attempt \(attempt): FAILED — \(error.localizedDescription)")
                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                    }
                }
            }
            // All attempts failed — keep pendingTurn so retryPendingTurn re-tries later.
            self.engine?.errorMessage = "Failed to end match after 3 attempts: \(lastError?.localizedDescription ?? "unknown")"
            self.isWaitingForOpponent = false
        }
    }

    private func applyOutcomes(_ terminal: TerminalOutcome, to match: GKTurnBasedMatch) {
        for p in match.participants {
            let isLocal = p.player?.gamePlayerID == localPlayerID
            switch terminal {
            case .tied: p.matchOutcome = .tied
            case .won:  p.matchOutcome = isLocal ? .won : .lost
            case .lost: p.matchOutcome = isLocal ? .lost : .won
            }
        }
    }

    private func finishTerminalSuccess() {
        self.pendingTurn = nil
        self.currentMatch = nil
        self.sharedActiveMatchID = nil
        self.isWaitingForOpponent = false
    }

    /// True if `match` is the game the user is actually in. Events for any *other*
    /// allowlisted match (a coexisting/orphaned/cross-device duplicate) must not
    /// hijack or tear down the visible game.
    private func isActiveMatch(_ match: GKTurnBasedMatch) -> Bool {
        match.matchID == currentMatch?.matchID || match.matchID == sharedActiveMatchID
    }

    /// As `isActiveMatch`, but also accepts an event when there is no active game
    /// yet (bootstrap) — e.g. the opponent moved first and we haven't loaded a
    /// match on this launch. Excludes the game-over state so a stray event can't
    /// bootstrap-hijack a finished board the user is still viewing.
    private func isActiveOrBootstrap(_ match: GKTurnBasedMatch) -> Bool {
        if isActiveMatch(match) { return true }
        return currentMatch == nil && sharedActiveMatchID == nil && engine?.isGameOver != true
    }

    /// Wait (briefly) for the engine's bridge init to complete before restoring a
    /// match, so an inbound turn event during the launch window can't race the
    /// staged C++ setup running on bridgeQueue. No-op once initialized.
    private func waitForEngineInit() async {
        var waited = 0
        while engine?.isInitialized != true && waited < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1s, up to ~5s
            waited += 1
        }
    }

    func forfeitMatch() {
        guard let match = currentMatch else { return }
        guard isAllowedMatch(match) else {
            engine?.errorMessage = FamilyMultiplayerError.unexpectedParticipants.localizedDescription
            return
        }

        Task {
            do {
                // Refresh match to get latest participant/turn state
                let fresh = try await GKTurnBasedMatch.load(withID: match.matchID)
                guard self.isAllowedMatch(fresh) else {
                    throw FamilyMultiplayerError.unexpectedParticipants
                }
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
                self.pendingTurn = nil
                self.leaveMultiplayerToModeSelection(preserveMatch: false)
            } catch {
                print("[GameCenter] forfeit FAILED: \(error.localizedDescription)")
                self.engine?.errorMessage = "Failed to forfeit: \(error.localizedDescription)"
            }
        }
    }

    /// Tracks last-loaded match data to avoid redundant reloads in poll
    private var lastLoadedData: Data?

    // MARK: - Polling

    func pollForMatchUpdate() {
        guard let match = currentMatch else { return }
        Task {
            do {
                // Use loadMatches() instead of load(withID:) to avoid stale cached data
                let matches = try await GKTurnBasedMatch.loadMatches()
                // The active match may have changed while this poll awaited — if so,
                // this poll is stale; don't act on it (avoids clobbering the new game).
                guard self.currentMatch?.matchID == match.matchID else {
                    print("[GameCenter] poll: active match changed mid-poll — discarding stale result")
                    return
                }
                guard let refreshed = matches.first(where: { $0.matchID == match.matchID }) else {
                    print("[GameCenter] poll: match not found in loadMatches() — navigating away")
                    self.isWaitingForOpponent = false
                    self.currentMatch = nil
                    self.pendingTurn = nil
                    self.sharedActiveMatchID = nil
                    self.engine?.isGameOver = false
                    self.engine?.showModeSelection = true
                    return
                }
                guard self.isAllowedMatch(refreshed) else {
                    print("[GameCenter] poll: match has unexpected participants — navigating away")
                    self.isWaitingForOpponent = false
                    self.currentMatch = nil
                    self.pendingTurn = nil
                    self.sharedActiveMatchID = nil
                    self.engine?.showModeSelection = true
                    return
                }
                self.currentMatch = refreshed
                let currentTurn = refreshed.currentParticipant?.player?.gamePlayerID ?? "nil"
                print("[GameCenter] poll: dataSize=\(refreshed.matchData?.count ?? 0), currentTurn=\(currentTurn), local=\(self.localPlayerID), waiting=\(self.isWaitingForOpponent), status=\(refreshed.status.rawValue)")

                // Check if match ended (opponent forfeited or match otherwise closed)
                if refreshed.status != .open && refreshed.status != .matching {
                    print("[GameCenter] poll: match is no longer open (status=\(refreshed.status.rawValue))")
                    self.handleMatchEnded(refreshed)
                    return
                }

                // Check if opponent quit (participant outcome)
                let opponentQuit = refreshed.participants.contains { p in
                    p.player != nil && p.player?.gamePlayerID != self.localPlayerID && p.matchOutcome == .quit
                }
                if opponentQuit {
                    print("[GameCenter] poll: opponent has quit")
                    self.handleMatchEnded(refreshed)
                    return
                }

                // Don't clobber an in-flight local move: while we have a pending
                // submission for THIS match, the server still holds pre-commit data
                // and reloading it would erase our move and re-enable "Your turn".
                // Identity-scoped so a stale pending for a different match can't
                // freeze the visible match's polling.
                if let pending = self.pendingTurn, pending.matchID == refreshed.matchID {
                    // Don't reload (would clobber our in-flight local move), but nudge
                    // the pending submission so a foregrounded session self-heals — e.g.
                    // we submitted the opening move before the opponent accepted the
                    // invite, and they've now resolved. retryPendingTurn no-ops if a
                    // submission is already running (isSubmitting guard).
                    print("[GameCenter] poll: pending submission for this match — nudging retry instead of reloading")
                    self.retryPendingTurn()
                    return
                }

                guard let data = refreshed.matchData, !data.isEmpty else {
                    print("[GameCenter] poll: no match data yet")
                    return
                }

                // Skip if data hasn't changed since last load
                if data == self.lastLoadedData && !self.isWaitingForOpponent {
                    return
                }

                let state: MultiplayerGameState
                do {
                    state = try JSONDecoder().decode(MultiplayerGameState.self, from: data)
                } catch {
                    print("[GameCenter] poll: DECODE FAILED — \(error)")
                    return
                }

                // Data changed — reload state (covers opponent moves, same-player
                // moves from another device, and waiting-for-first-move)
                print("[GameCenter] poll: data changed (\(self.lastLoadedData?.count ?? 0) → \(data.count)), loading state")
                self.isWaitingForOpponent = false
                self.lastLoadedData = data
                self.loadMatchState(state, from: refreshed)
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
            guard self.canUseMultiplayer, self.isAllowedMatch(match) else {
                print("[GameCenter] receivedTurnEvent: ignoring unexpected match \(match.matchID)")
                return
            }
            // Defer until the engine has finished bridge init — restoring over a
            // half-initialized C++ game can crash (null params before stage 1).
            await self.waitForEngineInit()
            guard self.engine?.isInitialized == true else {
                print("[GameCenter] receivedTurnEvent: engine still not initialized after wait — ignoring")
                return
            }
            // Only the active game (or first-game bootstrap) may take over the
            // engine. An event for a coexisting/duplicate match must not hijack
            // the visible game — assigning currentMatch IS the hijack.
            guard self.isActiveOrBootstrap(match) else {
                print("[GameCenter] receivedTurnEvent: ignoring non-active match \(match.matchID)")
                return
            }

            // Only take over the engine if we're actually in / awaiting a multiplayer
            // game. Assigning currentMatch IS the hijack surface, so do NOT install a
            // non-active match as current when we're in AI mode / on mode selection.
            guard self.engine?.gameMode == .multiplayer || self.isWaitingForOpponent else {
                print("[GameCenter] receivedTurnEvent: not in multiplayer mode, ignoring event")
                return
            }
            self.currentMatch = match

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
            guard self.canUseMultiplayer, self.isAllowedMatch(match) else { return }
            // Only tear down for the match we're actually in — a matchEnded for a
            // stale/duplicate match must not clobber the active game's state.
            guard self.isActiveMatch(match) else {
                print("[GameCenter] matchEnded: ignoring non-active match \(match.matchID)")
                return
            }
            await self.waitForEngineInit()
            guard self.engine?.isInitialized == true else {
                print("[GameCenter] matchEnded: engine still not initialized after wait — ignoring")
                return
            }
            self.currentMatch = match
            guard self.engine?.gameMode == .multiplayer || self.isWaitingForOpponent else { return }
            self.handleMatchEnded(match)
        }
    }

    // MARK: - Match End Handling

    private func handleMatchEnded(_ match: GKTurnBasedMatch) {
        let opponentQuit = match.participants.contains { p in
            p.player != nil && p.player?.gamePlayerID != self.localPlayerID && p.matchOutcome == .quit
        }
        print("[GameCenter] match ended (status=\(match.status.rawValue), opponentQuit=\(opponentQuit))")

        // Render the final board so the non-finishing player actually sees the
        // deciding move, rather than being blind-navigated to mode selection.
        var rendered = false
        if let data = match.matchData, !data.isEmpty,
           let state = try? JSONDecoder().decode(MultiplayerGameState.self, from: data),
           isAllowedState(state, resolvedIDs: Set(match.participants.compactMap { $0.player?.gamePlayerID })) {
            // Don't persist KVS here — the match is ending and KVS is cleared just below;
            // writing then clearing would be a redundant contradictory pair of iCloud writes.
            loadMatchState(state, from: match, persistKVS: false)
            engine?.isGameOver = true
            rendered = true
        }

        let message = resultMessage(for: match, opponentQuit: opponentQuit)

        self.isWaitingForOpponent = false
        self.pendingTurn = nil
        self.currentMatch = nil
        self.sharedActiveMatchID = nil

        if rendered {
            // Stay on the final board and show the result; user taps New to leave.
            // gameMode stays .multiplayer here, but isActiveOrBootstrap's game-over
            // exclusion prevents a stray event from hijacking the finished board.
            self.engine?.gameResultMessage = message
            self.engine?.showModeSelection = false
        } else {
            // No final state to show (e.g. forfeit before any move) — surface the
            // result and return to mode selection in a clean, non-multiplayer state.
            self.leaveMultiplayerToModeSelection(preserveMatch: false)
            self.engine?.errorMessage = message
        }
    }

    /// Exit a multiplayer game to mode selection in a coherent state. Crucially flips
    /// gameMode off .multiplayer so the globally-registered turn-event listener can't
    /// re-hijack the UI back into the (cancelled/ended) game. Pass preserveMatch:true
    /// to keep currentMatch/KVS for a later resume (e.g. a deliberate Cancel).
    func leaveMultiplayerToModeSelection(preserveMatch: Bool) {
        isWaitingForOpponent = false
        if !preserveMatch {
            currentMatch = nil
            sharedActiveMatchID = nil
        }
        engine?.gameMode = .ai
        engine?.isGameOver = false
        engine?.gameResultMessage = nil
        engine?.showModeSelection = true
    }

    /// Human-readable end-of-game result from the authoritative match outcomes.
    private func resultMessage(for match: GKTurnBasedMatch, opponentQuit: Bool) -> String {
        if opponentQuit {
            let oppName = match.participants.first { $0.player?.gamePlayerID != localPlayerID }?.player?.displayName ?? "Opponent"
            return "\(oppName) forfeited — you win!"
        }
        let localOutcome = match.participants.first { $0.player?.gamePlayerID == localPlayerID }?.matchOutcome
        switch localOutcome {
        case .won:  return "You won!"
        case .lost: return "You lost."
        case .tied: return "Tie game."
        default:    return "Game over."
        }
    }
}
