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
- (void)initStage3LoadGaddag:(NSString *)lexicon;
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
- (NSString *)nameForPlayerIndex:(int)index;
- (int)numberOfPlayers;
- (int)tilesRemainingInBag;
- (BOOL)isGameOver;
- (int)turnNumber;

// Move operations
- (NSArray<QBMoveInfo *> *)kibitzMoves:(int)count;
- (int)validateMoveString:(NSString *)moveString;
- (BOOL)commitMoveString:(NSString *)moveString;
- (void)commitPass;
- (void)commitExchangeWithTiles:(NSString *)tiles;

// AI play
- (nullable QBMoveInfo *)haveComputerPlay;

// History
- (int)historySize;
- (NSArray<QBHistoryEntry *> *)moveHistory;

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
            currentPlayerIsHuman:(BOOL)humanTurn;

@end

NS_ASSUME_NONNULL_END
