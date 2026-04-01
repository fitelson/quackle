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
- Multiplayer uses GKTurnBasedMatch with auto-match (GKMatchRequest with min/max 2 players)
- Opponent resolved from match participants by comparing gamePlayerID with localPlayerID
- NSGKFriendListUsageDescription in Info.plist for friends API access
- bestPlayableMatch() shared dedup logic: cleans non-playable/finished/duplicate matches; prefers data > paired > smallest matchID
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
- resumeCurrentMatch() refreshes match from Game Center and calls handleMatchFound
- Turn event callbacks (receivedTurnEventFor, matchEnded) only switch to multiplayer when already in multiplayer mode; otherwise silently update match reference
- loadActiveMatch() called after Game Center authentication; uses bestPlayableMatch() for consistent dedup
- Same online game can be open on multiple devices (iPhone + Mac) via iCloud KVS match ID sharing
- Active match ID stored in NSUbiquitousKeyValueStore (key: "activeMatchID"), syncs across devices within seconds
- loadActiveMatch and findOrCreateMatch check iCloud KVS first, then fall back to bestPlayableMatch()
- bestPlayableMatch() removes unpaired empty matches (no opponent yet) to force find(for:) to run fresh and pair with the other player's match
- handleMatchFound writes match ID to KVS; handleMatchEnded/forfeit clears it
- iCloud KVS entitlement: com.apple.developer.ubiquity-kvstore-identifier in entitlements
- Poll reloads state whenever match data changes (not just on turn change) — handles same-player cross-device moves
- One-time match nuke on new build (UserDefaults flag) clears stale matches from testing
- submitTurn retries up to 3 times with exponential backoff; re-fetches fresh match on retries
- pendingTurnData persisted to UserDefaults — survives app restart; cleared on match end/forfeit to prevent cross-match corruption
- forfeitMatch refreshes match from GC before quitting (avoids stale participant state); only clears local state on success
- handleMatchEnded navigates straight to mode selection (clears currentMatch, pendingTurnData, isWaitingForOpponent)
- WaitingForOpponentView Cancel button clears isWaitingForOpponent (prevents stuck-in-waiting after switching to AI)
- Score ties handled with .tied outcome for both players (not asymmetric won/lost)
- handleMatchFound uses do/catch for JSON decode (not try?) — shows error instead of silently starting new game on corrupted data
- QuackleBridge critical methods (startNewGame, haveComputerPlay, kibitzMoves, commitMove, restore*, moveHistory) are wrapped in C++ try/catch to prevent exceptions from crossing the ObjC boundary
- QuackleEngine uses a serial `bridgeQueue` (DispatchQueue) for background bridge work (init, AI play) via `withCheckedContinuation`, avoiding `Task.detached`
- AI/opponent move animations tracked via `animationTask` property; previous animation cancelled before starting new one
- initStage3LoadGaddag returns BOOL (NO if GADDAG file not found; move generation still works, just slower)
- Board restoration validates rowBlanks array bounds before access (guards against mismatched array sizes)
- RNG in haveComputerPlay seeded via `std::random_device` (not `std::time`)
- loadMatchState tracks matched players with flags to prevent double-assignment when player2GameCenterID is empty
- forfeitMatch uses do/catch with error reporting (not silent try?)
- Sheets use single `.sheet(item:)` with `ActiveSheet` enum (blankPicker, topMoves, history, skillSlider) — never multiple `.sheet(isPresented:)` on the same view
- Saved AI game cleared on app version change (CFBundleVersion compared via UserDefaults "lastAppBuild")
- QuackleBridge marked `@unchecked Sendable` (thread-safe via bridgeQueue serialization)
- `_UIReparentingView` console warning is a known SwiftUI framework bug with Menu on iOS — not fixable from app code, safe to ignore
- BlankPickerView sets engine state directly (no dismiss()+asyncAfter delay)
- buildMoveString uses guard-let for UnicodeScalar (no force unwrap)
- Module name is "Scrabble" (matches PRODUCT_NAME), use `@testable import Scrabble` in tests
- DataManager/ComputerPlayer ownership documented in QuackleBridge.mm comments
- Bridge return contract: collections return empty arrays, single objects return nullable nil (documented in QuackleBridge.h)
- Submit button uses explicit Text label with `.fixedSize()` to prevent macOS button text truncation (score was clipped without it)
- When copying .app to /Applications on macOS, `rm -rf` the old bundle first — macOS caches the old binary and may launch the stale version if you just `cp` over it
