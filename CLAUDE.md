# QuackleScrabble

Multiplatform (iOS + macOS) Scrabble game powered by the Quackle C++ engine.

## Build

```bash
# iOS Simulator
xcodebuild -project QuackleScrabble.xcodeproj -scheme QuackleScrabble -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# macOS (needs -allowProvisioningUpdates for Game Center entitlement)
xcodebuild -project QuackleScrabble.xcodeproj -scheme QuackleScrabble -destination 'platform=macOS' -allowProvisioningUpdates build
```

## Project structure

- `QuackleScrabble/App/` — ContentView, GameView, HandoffView, WaitingForOpponentView, sheet views (BlankPicker, History, TopMoves, SkillSlider)
- `QuackleScrabble/Bridge/` — QuackleEngine.swift (main Observable engine), QuackleBridge (Obj-C++ bridge to C++ Quackle)
- `QuackleScrabble/Views/Board/` — BoardView, SquareView
- `QuackleScrabble/Views/Rack/` — RackView
- `QuackleScrabble/Model/` — GameState (TilePlacement, MoveHistoryEntry, AIAnimTile, SavedGameState)
- `QuackleScrabble/Views/Game/` — OpponentRackView, AIAnimationOverlay, ScoreboardView, MoveInputView, ModeSelectionView
- `QuackleScrabble/Multiplayer/` — GameCenterManager, MultiplayerGameState
- `QuackleScrabble/QuackleScrabble.entitlements` — Game Center capability
- `QuackleScrabbleTests/` — Unit tests (ModelTests: Codable roundtrips, tile points, UUID identity)

## Key conventions

- Tile placement uses immediate DragGesture (not tap-to-place or system onDrag/onDrop)
- The "game" named coordinate space is defined on GameView's VStack and used by all drag gestures
- Board geometry (grid origin, square size, zoom state) is reported to the engine for drop-target calculation
- Drag-and-drop is zoom-aware: endDrag() inverse-transforms coordinates through scaleEffect + offset
- Rack tiles can be reordered by dragging within the rack (animated live preview)
- Game state persists across launches via UserDefaults (auto-saves after each move)
- LetterString is FixedLengthString (max 40 chars); use LongLetterString (std::string) for bag-sized data
- Bag() default constructor calls prepareFullBag(); always call clear() before toss() when restoring
- Bundle ID: `com.bef.quacklescrabble`
- Lexicon: CSW19
- GameMode enum: .ai (vs computer), .multiplayer (via Game Center)
- Multiplayer uses GKTurnBasedMatch AUTO-MATCH (`find(for:)`, min/max 2, NO `recipients`) gated by a hard-coded two-account allowlist (`FamilyMultiplayer`). Direct-invite (`recipients`) was tried and reverted: it requires the two accounts to be Game Center friends, which they are NOT (`loadFriends()` returns 0). Auto-match needs no friendship — this private app's turn-based match pool only ever contains the two configured accounts, and `isAllowedMatch` rejects any unexpected participant as defense-in-depth.
- Configured multiplayer Game Center IDs: `A:_efcfe63bc31fd01cf29ea407c71d780a` (`fitelson`) and `A:_ead7114711f507e29d1cf28ac791cfa7` (`Szwarch Of River Twilight`)
- Opponent resolved from match participants by comparing gamePlayerID with localPlayerID
- Only the two configured `gamePlayerID`s may enter multiplayer (`canUseMultiplayer`); unauthorized local accounts disable Play Online, and matches/events/polls/submissions with unexpected participants are ignored or rejected (`isAllowedMatch`/`isAllowedState`)
- No friends API: matchmaking is auto-match, so NSGKFriendListUsageDescription was removed from Info.plist
- bestPlayableMatch() is non-destructive: it SKIPS non-playable/finished/unpaired-empty matches during selection but never calls match.remove() (removing open matches breaks the other device's pending Game Center request). Comparator isBetterPlayableMatch(_:than:) prefers data > paired > smallest matchID
- findOrCreateMatch() and loadActiveMatch() both use bestPlayableMatch() for consistent match selection
- Match status .matching (invite pending) treated as playable alongside .open
- "…" menu shows "Resume Online Game" (active match) or "Play Online" (no match) when in AI mode; saves AI game before matchmaking
- Only the currentParticipant initializes a new match; the other player waits for first move
- Opponent display names resolved from match participants when loading state (var properties on MultiplayerGameState, not full-struct copies)
- GameCenterManager conforms to GKLocalPlayerListener for turn event callbacks
- receivedTurnEventFor uses do/catch for JSON decode (not try?) — logs decode failures
- Both WaitingForOpponentView and GameView poll Game Center every 3s via `.task`-based async loops
- GameView polls whenever in multiplayer mode (not just opponent's turn) — ensures forfeits detected even on your turn
- Poll skips redundant reloads via lastLoadedData byte comparison
- Poll navigates to mode selection if match disappears from loadMatches() (prevents stuck state)
- Poll checks match status and participant .quit outcomes to detect forfeit/end
- onMultiplayerMoveCommitted callback: sole setup in ensureMultiplayerCallback(), called from handleMatchFound (handles ties correctly)
- ensureMultiplayerCallback() always overwrites the callback every time a multiplayer game is entered — survives game-mode switches
- startNewGame() must NOT clear onMultiplayerMoveCommitted
- isLocalPlayerTurn is a stored property updated in refreshState(), not computed (bridge calls aren't tracked by @Observable)
- Multiplayer move history managed via MultiplayerGameState serialization, not bridge (bridge only has moves since last restore)
- appendLatestMoveToHistory() reads bridge history post-commit and appends to accumulated moveHistory
- Opponent moves animate (3-phase flip+fly) in multiplayer via board diff in loadMultiplayerState
- Hypothetical moves: players can place tiles and see scores while waiting for opponent's turn
  - Drag allowed when !isLocalPlayerTurn in multiplayer; validation ignores rack check (InvalidTiles 0x0001)
  - Shows "Score: N" label (orange) instead of Submit button; Clear button available
  - Bridge method scoreMoveStringIgnoringRack: scores valid board placements regardless of rack ownership
- Submit button shows score preview: "Submit (N)" for valid tentative moves
- Bridge has separate methods for AI games (startNewGame/restoreGame) and two-human games (startNewTwoHumanGame/restoreTwoHumanGame)
- Game state persistence (UserDefaults) only applies to AI mode; multiplayer state lives in GameKit match data
- ModeSelectionView shown on first launch (no saved game) or when user taps New; shows engine.errorMessage below Play Online button
- GameView shows engine.errorMessage as an alert (covers multiplayer errors: failed turn, forfeit, match end)
- "…" Menu next to New button: AI Skill Level (always), Switch to AI Game (in multiplayer), Resume Online Game / Play Online (in AI)
- Game switching preserves both games: AI saves to UserDefaults, multiplayer lives in Game Center match data
- switchToAIGame() loads saved AI game or starts new; preserves onMultiplayerMoveCommitted callback
- "Resume Online Game" / "Play Online" both route through findOrCreateMatch() (the standalone resumeCurrentMatch() was removed)
- Turn event callbacks (receivedTurnEventFor, matchEnded) only switch to multiplayer when already in multiplayer mode; otherwise silently update match reference
- loadActiveMatch() called after Game Center authentication; uses bestPlayableMatch() for consistent dedup
- Same online game can be open on multiple devices (iPhone + Mac) via iCloud KVS match ID sharing
- Active match ID stored in NSUbiquitousKeyValueStore (key: "activeMatchID"), syncs across devices within seconds
- loadActiveMatch and findOrCreateMatch check iCloud KVS first, then fall back to bestPlayableMatch()
- bestPlayableMatch() skips unpaired empty matches (no opponent yet) during selection so find(for:) can auto-match fresh, but does NOT remove them — removal disrupts the other device's pending request
- handleMatchFound writes match ID to KVS; handleMatchEnded/forfeit clears it
- iCloud KVS entitlement: com.apple.developer.ubiquity-kvstore-identifier in entitlements (declared in project.yml, regenerated by xcodegen)
- Poll reloads state whenever match data changes (not just on turn change) — handles same-player cross-device moves
- submitTurn retries up to 3 times with exponential backoff; re-fetches fresh match on retries
- Pending turn stored as PendingTurn{matchID, data} struct (Codable, UserDefaults key "pendingTurn"), not bare Data — survives app restart; cleared on match end/forfeit to prevent cross-match corruption
- submitTurn and retryPendingTurn both bail+clear pendingTurn if the fresh match's currentParticipant is no longer the local player (turn already advanced) — prevents double-submit/stale-data overwrite
- forfeitMatch refreshes match from GC before quitting (avoids stale participant state); only clears local state on success
- handleMatchEnded navigates straight to mode selection (clears currentMatch, pendingTurn, isWaitingForOpponent); endMatch success also clears currentMatch/pendingTurn/KVS
- WaitingForOpponentView Cancel button clears isWaitingForOpponent (prevents stuck-in-waiting after switching to AI)
- Score ties handled with .tied outcome for both players (not asymmetric won/lost)
- handleMatchFound uses do/catch for JSON decode (not try?) — shows error instead of silently starting new game on corrupted data
- QuackleBridge critical methods (startNewGame, haveComputerPlay, kibitzMoves, commitMove, restore*, moveHistory) are wrapped in C++ try/catch to prevent exceptions from crossing the ObjC boundary
- QuackleEngine uses a serial `bridgeQueue` (DispatchQueue) for background bridge work (init, AI play) via `withCheckedContinuation`, avoiding `Task.detached`
- AI/opponent move animations tracked via `animationTask` property; previous animation cancelled before starting new one
- initStage3LoadGaddag returns BOOL (NO if GADDAG file not found; move generation still works, just slower)
- Board restoration validates rowBlanks array bounds before access (guards against mismatched array sizes)
- RNG in haveComputerPlay seeded via `std::random_device` (not `std::time`)
- AI has TWO INDEPENDENT sliders (decoupled): `skillLevel` (0–1) drives move quality (meanLoss/stdDev, applied at new-game time) and `bingoKnowledge` (0–1, stored, default 0.10) drives bingo vocabulary (applied per turn). `bingoKnowledge` is NO LONGER derived from skillLevel (was `pow(skillLevel, …)`); it's a stored, separately-persisted property (SavedGameState, versioned decodeIfPresent ?? 0.10). Both shown as two sliders in SkillSliderView and as the "…" menu label "AI Skill: X · Bingo N%"
- Bingo vocabulary is a deterministic DRAW-PROBABILITY model (not a hash, not a per-turn dice roll, not a normal-CDF approximation): the bridge scores each bingo's 7 newly-laid tiles by `logCount = Σ ln C(bagCount[L], timesUsed[L])` (`bingoDrawLogCount`), then KEEPS the bingo iff `logCount >= bingoLnQuantile(1 - bingoKnowledge)` — the (1 - knowledge) quantile of the REAL bingo distribution. So the slider tracks TRUE frequency: 10% ≈ the 10% most-probable bingos (RETINAS-class racks first, rare-tile racks like QUICKLY last). `kBingoQuantile[21]` is the empirical 5%-spaced percentile curve of `lnDrawCount` over the 33,839 drawable 7-letter words in the actual CSW19 lexicon (extracted by walking the bundled `data/lexica/csw19.dawg`; regenerate with `tools/bingo_calib.py`, which parses the V1 DAWG format directly). Sanity: REGIONS (ln 12.83) → ~98th percentile (top ~2%), so it's known at the 5% slider; matches its real-world top-2% bingo rank. Non-bingo moves always stay; falls back to all moves if the filter empties the pool. Top-100 candidate pool still applies
- Candidate-move pool size is 100 (not 50): bingo-rich racks fill the top 50 entirely with bingos, starving the non-bingo options
- AI skill→Quackle mapping is piecewise-linear via skillCurve(low:medium:high:) so the slider midpoint is a true intermediate anchor: skillMeanLoss 20/10/2 and skillStdDev 8/6/2 at skill 0/0.5/1 (NormalPlayer δ/σ)
- canCommitCurrentTurn guard blocks commitTentativeMove/pass/exchangeTiles when it's not your turn or the game is over (sets errorMessage "It is not your turn"); Exchange confirm button also disabled off-turn/game-over
- Multiplayer state restore passes turnNumber, scorelessTurns, gameOver down to the bridge (restoreTwoHumanGame), which sets them on the C++ GamePosition via new setters (setTurnNumber/setScorelessTurnsInARow/setGameOver in libquackle/game.h — setTurnNumber moved protected→public)
- MultiplayerGameState has a custom Codable: turnNumber back-inferred for legacy saves lacking it (player-2-to-move → maxHistoryTurn, player-1-to-move → maxHistoryTurn+1)
- loadMultiplayerState/startMultiplayerGame thread matchID through to engine.multiplayerMatchID; opponent-move animation diff only runs when incoming state is the same visible match (isSameVisibleMatch) — prevents false animations on match/device switch
- BoardView hides the destination square of an in-flight animating tile (isAnimatingTarget) so the tile isn't drawn twice (static + flying)
- appendLatestMoveToHistory() accumulates move history for BOTH modes (called on each commit/pass/exchange and after each AI move); attributes/dedups by player INDEX (turn, playerIndex), not name; reads running totals from live bridge.score(forPlayerIndex:). There is NO full-replace refresh (the bridge only holds moves since the last restore — a full-replace would drop pre-restore history); showMoveHistory just presents the accumulated list. The History button no longer reads the bridge (closes a data race during AI compute)
- MoveHistoryEntry and SavedGameState/MultiplayerGameState carry a playerIndex/version field; AI restore persists turnNumber so post-restore history doesn't collide with saved entries on the (turn, playerIndex) dedup key
- loadMatchState tracks matched players with flags to prevent double-assignment when player2GameCenterID is empty
- forfeitMatch uses do/catch with error reporting (not silent try?)
- Sheets use single `.sheet(item:)` with `ActiveSheet` enum (blankPicker, topMoves, history, skillSlider) — never multiple `.sheet(isPresented:)` on the same view
- Saved AI game cleared on app version change (CFBundleVersion compared via UserDefaults "lastAppBuild")
- QuackleBridge marked `@unchecked Sendable`; the serialization is now actually honored — destructive `_game` mutations (startNewGame/restoreGame/restoreTwoHumanGame/startNewTwoHumanGame) run through `withBridgeSync` (`bridgeQueue.sync`) so they can't `delete _game` while a `haveComputerPlay` is mid-flight on that queue (use-after-free). AI compute is tracked by `aiComputeInFlight` (gates saveGameState; History no longer reads the bridge) and an `aiGeneration` token + cancellable `aiTriggerTask` discard a stale AI result against a new game. `haveComputerPlay` returns nil unless the current player is a computer (never commits for the human)
- `_UIReparentingView` console warning is a known SwiftUI framework bug with Menu on iOS — not fixable from app code, safe to ignore
- BlankPickerView sets engine state directly (no dismiss()+asyncAfter delay)
- buildMoveString uses guard-let for UnicodeScalar (no force unwrap)
- Module name is "Scrabble" (matches PRODUCT_NAME), use `@testable import Scrabble` in tests
- DataManager/ComputerPlayer ownership documented in QuackleBridge.mm comments
- Bridge return contract: collections return empty arrays, single objects return nullable nil (documented in QuackleBridge.h)
- Submit button uses explicit Text label with `.fixedSize()` to prevent macOS button text truncation (score was clipped without it)
- When copying .app to /Applications on macOS, `rm -rf` the old bundle first — macOS caches the old binary and may launch the stale version if you just `cp` over it (the bundle is root-owned, so use `sudo -A`)
- END-OF-GAME SCORES: read endgame-adjusted scores at game over via `bridge.finalScore(forPlayerIndex:)` (wraps Quackle's `endgameAdjustedScores()`), NOT raw `score(forPlayerIndex:)` — the deadwood/unplayed-tiles bonus is only folded in by `endgameAdjustedScores`. Used by refreshState, exportMultiplayerState, saveGameState, and the won/lost/tie decision whenever isGameOver. The adjustment is only reconstructable while the bonus move is staged (right after the final commit), so capture/persist the adjusted score at save/export time. finalScoreForPlayerIndex guards the restored case (staged move is a Nonmove with score -9999): only trust the adjustment when the staged move is a real `UnusedTilesBonus`, else return the (already-persisted) raw score
- Multiplayer-exit hardening: `leaveMultiplayerToModeSelection(preserveMatch:)` flips `gameMode` off `.multiplayer` on every exit to mode selection (WaitingForOpponent Cancel, forfeit success, handleMatchEnded no-render) so the globally-registered turn-event listener can't re-hijack the UI back into a cancelled/finished game. `receivedTurnEvent` assigns `currentMatch = match` only AFTER the mode-gate (assigning it IS the hijack surface); `isActiveOrBootstrap` excludes the game-over state from its bootstrap branch
- Terminal end-match (`runTerminalEnd`/`retryPendingTurn`) only treats the submission as success when `match.status == .ended`; if the turn advanced but the match is still open it KEEPS pendingTurn for retry (never silently strands the opponent). submit/terminal retries only adopt the refreshed match as `currentMatch` if it's still the active match. retryPendingTurn does NOT drop the pending move on a transient `!canUseMultiplayer`
- PendingTurn carries an optional terminal outcome; `isSubmitting` guards against a concurrent retry launching a duplicate submission
- commitPass/commitExchange return BOOL; pass()/exchangeTiles() skip the post-commit submit/AI-trigger block on refusal (e.g. exchange below a full rack — the bridge enforces bag ≥ 7). validate/score bridge methods are wrapped in C++ try/catch like the commit paths
- placeTile bounds-checks row/col and placeBlankAs guards pendingBlankRow/Col ≥ 0 (a poll reload can reset pendingBlank mid-blank-picker → would otherwise crash on board[-1][-1]); endDrag rejects negative pre-truncation drop coords (off-top/left no longer maps to A1)
- AIAnimationOverlay is zoom/pan-aware: it forward-transforms board-target positions through the same scaleEffect(anchor:)+offset as BoardView (inverse of endDrag's drop math) and scales tile size by boardZoomScale
- SavedGameState has a versioned custom Codable (decodeIfPresent + defaults) so adding a field never silently discards an in-progress AI game; it persists scorelessTurns + turnNumber, and AI restore (restoreGameWithHumanName:) sets scorelessTurns/turnNumber/gameOver on the C++ position (symmetric with restoreTwoHumanGame)
- bingoKnowledge slider is 0…1 (step 0.05); triggerAIIfNeeded clamps it to [0,1] before passing to the bridge. The bridge's knownBingo also clamps and short-circuits ≤0 (no bingos) / ≥1 (all bingos)
- Launch screen uses the `UILaunchScreen` Info.plist dict (the orphaned LaunchScreen.storyboard was removed); `*.profraw` coverage artifacts are gitignored
- Test target runs on iOS AND macOS (`supportedDestinations: [iOS, macOS]`)
- PLAYED-THRU MARK (`.`, byte value 2 = `QUACKLE_PLAYED_THRU_MARK`) MUST NEVER reach the model board, the display, or a saved game. It only legitimately exists inside move STRINGS (the tiles you play "through"), never as a committed board tile. Hardened at four layers: (1) the bridge boundary — `letterAtRow:`/`isVacantAtRow:` treat any non-letter cell (`!QUACKLE_ALPHABET_PARAMETERS->isSomeLetter(letter)`) as empty/vacant, a no-op on healthy boards since every real tile is `isSomeLetter`; (2) `restoreGame`/`restoreTwoHumanGame` board-placement loops SKIP any cell whose encoding isn't a single real letter (`encoded.length() != 1 || !isSomeLetter(encoded[0])`) — never re-injecting a saved `.`; (3) `saveGameState`/`exportMultiplayerState` skip `.`/empty cells when building `savedBoard`; (4) `loadSavedGame` discards a save that fails the tile-conservation check (below). The `.` round-trip (save→restore→re-save) was the AI-board corruption bug — it surfaced as a "." tile on the board and vanishing tiles after an AI→online→AI switch
- RESTORE LOCATION RE-SYNC (root cause of "tiles disappear after a restore, on the next move"): a `GamePosition`'s history location is `(currentPlayer().id(), turnNumber())` (game.h `GamePosition::location()`). `addPosition()` records the History's `currentLocation` BEFORE the restore applies the saved `currentPlayer`/`turnNumber`, so those setters move the position's location while `currentLocation` stays stale. The next `commitMove()` → `addClonePosition()` → `eraseAfter(currentLocation)` then erases THIS position (its location now sorts after the stale one), leaving the list empty → `commitMove` builds a FRESH `GamePosition` (bag=86, turn=1, empty board) and the whole restored board vanishes on the first move. FIX: both `restoreGame`/`restoreTwoHumanGame` call `_game->setCurrentPosition(_game->currentPosition().location())` after all scalar+board setup to re-sync `currentLocation`. This is the actual bug behind the AI→online→AI tile loss; the played-thru-`.` symptoms were downstream of the board being wiped under a played-through move. Verified live via a temporary tile-count DIAG (commit went `before=7 after=2 bag=86 turn=1` before the fix → `before=5 after=6 bag=80 turn=2` after)
- Both restores (`restoreGame`/`restoreTwoHumanGame`) set the SCALAR position fields (bag, racks, currentPlayer, turnNumber, scorelessTurns, gameOver) FIRST, immediately after `addPosition()`, and do the fault-prone board placement + `ensureBoardIsPreparedForAnalysis()` (walks the GADDAG, may be absent) LAST. Both FAIL CLOSED — `catch { delete _game; _game = nullptr; }` — so a throw mid-restore never leaves a half-built game with `addPosition()`'s fresh values (bag=86, turn=1) alongside applied scores. The old ordering (board prep before `setBag`/`setTurnNumber`, exception swallowed) was what produced the corrupt bag=86/turn=1-with-scores saves
- `loadSavedGame` validates the decoded save before trusting it: (a) TILE CONSERVATION — a valid English (CSW19) position always has exactly 100 tiles across `bag + board + racks` (counting only real-letter board cells); if the decoded save doesn't sum to 100 it's discarded (`removeObject(forKey:"savedGameState")` + return false → caller starts a fresh game); (b) after the restore, `bridge.numberOfPlayers() > 0` (catches the fail-closed case). A corrupt save thus auto-heals to a new game instead of presenting a broken board — no manual clearing needed
- macOS `/Applications` deploy when the `sudo -A` askpass dialog fails: `/Applications` is group-writable by `admin`, so RENAME the stale root-owned bundle aside (`mv /Applications/Scrabble.app /Applications/.Scrabble.old.<ts>.app` — a rename needs only parent-dir write, not write on the root-owned contents) then `cp -R` the fresh build in. Leaves hidden `.Scrabble.old.*.app` leftovers to clean later with `sudo rm -rf /Applications/.Scrabble.old.*.app`
