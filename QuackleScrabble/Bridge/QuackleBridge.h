#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface QBTileInfo : NSObject
@property (nonatomic) int row;
@property (nonatomic) int col;
@property (nonatomic, copy) NSString *letter;
@property (nonatomic) int points;
@property (nonatomic) BOOL isBlank;
@end

@interface QBMoveInfo : NSObject
@property (nonatomic, copy) NSString *moveDescription;
@property (nonatomic) int score;
@property (nonatomic) double equity;
@property (nonatomic) int moveType; // 0=place, 1=exchange, 2=pass, 3=nonmove
@property (nonatomic, copy) NSArray<QBTileInfo *> *placedTiles; // tiles placed on board (Place moves only)
@end

@interface QBHistoryEntry : NSObject
@property (nonatomic) int turn;
@property (nonatomic) int playerIndex;
@property (nonatomic, copy) NSString *playerName;
@property (nonatomic, copy) NSString *moveDescription;
@property (nonatomic) int score;
@property (nonatomic) int totalScore;
@end

@interface QuackleBridge : NSObject

+ (instancetype)shared;

// Initialization
- (BOOL)initializeWithDataPath:(NSString *)dataPath lexicon:(NSString *)lexicon;

// Staged initialization (for progress reporting)
- (void)initStage1SetupWithDataPath:(NSString *)dataPath;
- (BOOL)initStage2LoadDawg:(NSString *)lexicon;
- (BOOL)initStage3LoadGaddag:(NSString *)lexicon;
- (void)initStage4LoadStrategy:(NSString *)lexicon;
- (void)initStageFinalize;

// Game management
- (void)startNewGameWithHumanName:(NSString *)name
                       aiMeanLoss:(double)meanLoss
                         aiStdDev:(double)stdDev;

// Board state
- (int)boardRows;
- (int)boardCols;
- (NSString *)letterAtRow:(int)row col:(int)col;
- (BOOL)isBlankAtRow:(int)row col:(int)col;
- (BOOL)isVacantAtRow:(int)row col:(int)col;
- (int)letterMultiplierAtRow:(int)row col:(int)col;
- (int)wordMultiplierAtRow:(int)row col:(int)col;

// Current player
- (NSString *)currentPlayerName;
- (BOOL)isCurrentPlayerHuman;
- (NSArray<NSString *> *)currentPlayerRack;
- (int)scoreForPlayerIndex:(int)index;
// Endgame-adjusted score: at game over, includes the unplayed-tiles (deadwood)
// bonus/penalty that Quackle stages but does not fold into the raw score. Equals
// the raw score when the game is not over. Use this for ALL terminal scoring
// (final scoreboard, win/loss/tie). NOTE: the adjustment is only reconstructable
// while the bonus move is still staged (i.e. right after the final commit, before
// any restore) — capture/persist it at save/export time, not after a reload.
- (int)finalScoreForPlayerIndex:(int)index;
- (NSString *)nameForPlayerIndex:(int)index;
- (int)numberOfPlayers;
- (int)tilesRemainingInBag;
- (BOOL)isGameOver;
- (int)turnNumber;
- (int)scorelessTurns;

// Move operations
// Convention: collection methods return empty arrays on error/no-data;
// single-object methods (haveComputerPlay) return nullable nil on error.
- (NSArray<QBMoveInfo *> *)kibitzMoves:(int)count;
- (int)validateMoveString:(NSString *)moveString;
- (int)scoreMoveString:(NSString *)moveString;
- (int)scoreMoveStringIgnoringRack:(NSString *)moveString;
- (BOOL)commitMoveString:(NSString *)moveString;
// Return whether a move was actually committed (NO if refused, e.g. exchange with
// fewer than a full rack in the bag, or a C++ exception).
- (BOOL)commitPass;
- (BOOL)commitExchangeWithTiles:(NSString *)tiles;

// AI play
// bingoKnowledge (0..1): fraction of bingo vocabulary the AI knows, ordered by
// draw-probability (common-letter racks known first, rare-tile racks last). Deterministic.
- (nullable QBMoveInfo *)haveComputerPlayWithBingoKnowledge:(double)bingoKnowledge;

// History
- (int)historySize;
- (NSArray<QBHistoryEntry *> *)moveHistory;

// Current player index (0 or 1)
- (int)currentPlayerIndex;

// Save/Restore
- (NSArray<NSString *> *)rackForPlayerIndex:(int)index;
- (NSArray<NSString *> *)bagTiles;
- (void)restoreGameWithHumanName:(NSString *)name
                      humanFirst:(BOOL)humanFirst
                      aiMeanLoss:(double)meanLoss
                        aiStdDev:(double)stdDev
                    boardLetters:(NSArray<NSArray<NSString *> *> *)boardLetters
                     boardBlanks:(NSArray<NSArray<NSNumber *> *> *)boardBlanks
                    playerScores:(NSArray<NSNumber *> *)scores
                     playerRacks:(NSArray<NSArray<NSString *> *> *)racks
                        bagTiles:(NSArray<NSString *> *)bag
            currentPlayerIsHuman:(BOOL)humanTurn
                  scorelessTurns:(int)scorelessTurns
               currentTurnNumber:(int)turnNumber
                        gameOver:(BOOL)gameOver;

// Multiplayer (two human players)
- (void)startNewTwoHumanGameWithPlayer1:(NSString *)name1
                                player2:(NSString *)name2;

- (void)restoreTwoHumanGameWithPlayer1:(NSString *)name1
                               player2:(NSString *)name2
                          boardLetters:(NSArray<NSArray<NSString *> *> *)boardLetters
                           boardBlanks:(NSArray<NSArray<NSNumber *> *> *)boardBlanks
                          playerScores:(NSArray<NSNumber *> *)scores
                          playerRacks:(NSArray<NSArray<NSString *> *> *)racks
                              bagTiles:(NSArray<NSString *> *)bag
                    currentPlayerIndex:(int)currentIdx
                      currentTurnNumber:(int)turnNumber
                         scorelessTurns:(int)scorelessTurns
                               gameOver:(BOOL)gameOver;

@end

NS_ASSUME_NONNULL_END
