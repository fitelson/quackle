#import "QuackleBridge.h"

#include <string>
#include <vector>
#include <iostream>
#include <random>
#include <ctime>
#include <cmath>

#include "datamanager.h"
#include "game.h"
#include "player.h"
#include "computerplayer.h"
#include "computerplayercollection.h"
#include "boardparameters.h"
#include "alphabetparameters.h"
#include "lexiconparameters.h"
#include "strategyparameters.h"
#include "move.h"
#include "board.h"
#include "bag.h"
#include "rack.h"
#include "trademarkedboards.h"

using namespace Quackle;

// Helper: UVString to NSString
static NSString *uvToNS(const UVString &s) {
    return [NSString stringWithUTF8String:s.c_str()];
}

// Helper: NSString to std::string
static std::string nsToStd(NSString *s) {
    return std::string([s UTF8String]);
}

@implementation QBTileInfo
@end

@implementation QBMoveInfo
@end

@implementation QBHistoryEntry
@end

@interface QuackleBridge () {
    Quackle::DataManager _dataManager;
    Quackle::Game *_game;
    BOOL _initialized;
}
@end

@implementation QuackleBridge

+ (instancetype)shared {
    static QuackleBridge *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[QuackleBridge alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _game = nullptr;
        _initialized = NO;
    }
    return self;
}

- (BOOL)initializeWithDataPath:(NSString *)dataPath lexicon:(NSString *)lexicon {
    if (_initialized) return YES;
    [self initStage1SetupWithDataPath:dataPath];
    if (![self initStage2LoadDawg:lexicon]) return NO;
    [self initStage3LoadGaddag:lexicon];
    [self initStage4LoadStrategy:lexicon];
    [self initStageFinalize];
    return YES;
}

- (void)initStage1SetupWithDataPath:(NSString *)dataPath {
    std::string dataDir = nsToStd(dataPath);
    _dataManager.setComputerPlayers(ComputerPlayerCollection::fullCollection());
    _dataManager.setBackupLexicon("twl06");
    _dataManager.setAppDataDirectory(dataDir);
    _dataManager.setAlphabetParameters(new EnglishAlphabetParameters);
    _dataManager.setBoardParameters(new ScrabbleBoard());
}

- (BOOL)initStage2LoadDawg:(NSString *)lexicon {
    std::string lexName = nsToStd(lexicon);
    std::string dawgFile = LexiconParameters::findDictionaryFile(lexName + ".dawg");
    if (dawgFile.empty()) {
        NSLog(@"QuackleBridge: Could not find dawg file for %@", lexicon);
        return NO;
    }
    _dataManager.lexiconParameters()->loadDawg(dawgFile);
    return YES;
}

- (void)initStage3LoadGaddag:(NSString *)lexicon {
    std::string lexName = nsToStd(lexicon);
    std::string gaddagFile = LexiconParameters::findDictionaryFile(lexName + ".gaddag");
    if (!gaddagFile.empty()) {
        _dataManager.lexiconParameters()->loadGaddag(gaddagFile);
    }
}

- (void)initStage4LoadStrategy:(NSString *)lexicon {
    std::string lexName = nsToStd(lexicon);
    _dataManager.strategyParameters()->initialize(lexName);
}

- (void)initStageFinalize {
    _initialized = YES;
    NSLog(@"QuackleBridge: Initialized");
}

- (void)startNewGameWithHumanName:(NSString *)name
                       aiMeanLoss:(double)meanLoss
                         aiStdDev:(double)stdDev {
    delete _game;
    _game = new Game;

    PlayerList players;

    // Human player
    Player human(MARK_UV(nsToStd(name)), Player::HumanPlayerType, 0);
    players.push_back(human);

    // AI player using NormalPlayer
    Player computer(MARK_UV("AI"), Player::ComputerPlayerType, 1);
    NormalPlayer *ai = new NormalPlayer(meanLoss, stdDev, MARK_UV("Intermediate"));
    computer.setComputerPlayer(ai);
    players.push_back(computer);

    _game->setPlayers(players);
    _game->associateKnownComputerPlayers();
    _game->addPosition();

    NSLog(@"QuackleBridge: New game started - %@ vs AI (NormalPlayer delta=%.1f sigma=%.1f)",
          name, meanLoss, stdDev);
}

#pragma mark - Board State

- (int)boardRows { return QUACKLE_BOARD_PARAMETERS->height(); }
- (int)boardCols { return QUACKLE_BOARD_PARAMETERS->width(); }

- (NSString *)letterAtRow:(int)row col:(int)col {
    if (!_game || !_game->hasPositions()) return @"";
    const Board &board = _game->currentPosition().board();
    if (board.letter(row, col) == QUACKLE_NULL_MARK) return @"";

    Letter letter = board.letter(row, col);
    UVString str = QUACKLE_ALPHABET_PARAMETERS->userVisible(letter);
    return uvToNS(str);
}

- (BOOL)isBlankAtRow:(int)row col:(int)col {
    if (!_game || !_game->hasPositions()) return NO;
    const Board &board = _game->currentPosition().board();
    return board.isBlank(row, col);
}

- (BOOL)isVacantAtRow:(int)row col:(int)col {
    if (!_game || !_game->hasPositions()) return YES;
    return _game->currentPosition().board().letter(row, col) == QUACKLE_NULL_MARK;
}

- (int)letterMultiplierAtRow:(int)row col:(int)col {
    return QUACKLE_BOARD_PARAMETERS->letterMultiplier(row, col);
}

- (int)wordMultiplierAtRow:(int)row col:(int)col {
    return QUACKLE_BOARD_PARAMETERS->wordMultiplier(row, col);
}

#pragma mark - Current Player

- (NSString *)currentPlayerName {
    if (!_game || !_game->hasPositions()) return @"";
    return uvToNS(_game->currentPosition().currentPlayer().name());
}

- (BOOL)isCurrentPlayerHuman {
    if (!_game || !_game->hasPositions()) return YES;
    return _game->currentPosition().currentPlayer().type() == Player::HumanPlayerType;
}

- (NSArray<NSString *> *)currentPlayerRack {
    if (!_game || !_game->hasPositions()) return @[];

    const Rack &rack = _game->currentPosition().currentPlayer().rack();
    LetterString tiles = rack.tiles();
    NSMutableArray *result = [NSMutableArray array];
    for (unsigned int i = 0; i < tiles.length(); ++i) {
        Letter letter = tiles[i];
        UVString str = QUACKLE_ALPHABET_PARAMETERS->userVisible(letter);
        [result addObject:uvToNS(str)];
    }
    return result;
}

- (int)scoreForPlayerIndex:(int)index {
    if (!_game || !_game->hasPositions()) return 0;
    if (index < 0 || index >= (int)_game->currentPosition().players().size()) return 0;
    return _game->currentPosition().players()[index].score();
}

- (NSString *)nameForPlayerIndex:(int)index {
    if (!_game || !_game->hasPositions()) return @"";
    if (index < 0 || index >= (int)_game->currentPosition().players().size()) return @"";
    return uvToNS(_game->currentPosition().players()[index].name());
}

- (int)numberOfPlayers {
    if (!_game || !_game->hasPositions()) return 0;
    return (int)_game->currentPosition().players().size();
}

- (int)tilesRemainingInBag {
    if (!_game || !_game->hasPositions()) return 0;
    return (int)_game->currentPosition().bag().size();
}

- (BOOL)isGameOver {
    if (!_game || !_game->hasPositions()) return NO;
    return _game->currentPosition().gameOver();
}

- (int)turnNumber {
    if (!_game || !_game->hasPositions()) return 0;
    return _game->currentPosition().turnNumber();
}

#pragma mark - Move Operations

- (NSArray<QBMoveInfo *> *)kibitzMoves:(int)count {
    if (!_game || !_game->hasPositions()) return @[];

    _game->currentPosition().kibitz(count);
    const MoveList &moves = _game->currentPosition().moves();

    NSMutableArray *result = [NSMutableArray array];
    for (const auto &m : moves) {
        QBMoveInfo *info = [[QBMoveInfo alloc] init];
        UVString desc = m.toString();
        if (m.action == Move::Exchange || m.action == Move::BlindExchange) {
            // Replace leading "-" with "Exch: "
            if (!desc.empty() && desc[0] == '-') {
                desc = MARK_UV("Exch: ") + desc.substr(1);
            }
        } else if (m.action == Move::Pass) {
            desc = MARK_UV("Pass");
        }
        info.moveDescription = uvToNS(desc);
        info.score = m.effectiveScore();
        info.equity = m.equity;
        info.moveType = (int)m.action;
        [result addObject:info];
    }
    return result;
}

- (int)validateMoveString:(NSString *)moveString {
    if (!_game || !_game->hasPositions()) return -1;

    std::string str = nsToStd(moveString);
    size_t spacePos = str.find(' ');
    if (spacePos == std::string::npos) return -1;

    std::string position = str.substr(0, spacePos);
    std::string word = str.substr(spacePos + 1);
    if (position.empty() || word.empty()) return -1;

    NSLog(@"QuackleBridge: validateMove position='%s' word='%s'", position.c_str(), word.c_str());

    LetterString encodedWord = QUACKLE_ALPHABET_PARAMETERS->encode(MARK_UV(word));
    Move move = Move::createPlaceMove(MARK_UV(position), encodedWord);

    int result = _game->currentPosition().validateMove(move);
    NSLog(@"QuackleBridge: validateMove result=%d", result);
    return result;
}

- (BOOL)commitMoveString:(NSString *)moveString {
    if (!_game || !_game->hasPositions()) return NO;

    std::string str = nsToStd(moveString);
    size_t spacePos = str.find(' ');
    if (spacePos == std::string::npos) return NO;

    std::string position = str.substr(0, spacePos);
    std::string word = str.substr(spacePos + 1);
    if (position.empty() || word.empty()) return NO;

    LetterString encodedWord = QUACKLE_ALPHABET_PARAMETERS->encode(MARK_UV(word));
    Move move = Move::createPlaceMove(MARK_UV(position), encodedWord);

    int validity = _game->currentPosition().validateMove(move);
    NSLog(@"QuackleBridge: commitMove validity=%d for '%s %s'", validity, position.c_str(), word.c_str());
    if (validity != 0) return NO;

    // Score the move before committing (so effectiveScore() is set)
    _game->currentPosition().scoreMove(move);
    NSLog(@"QuackleBridge: move scored %d points", move.score);

    _game->commitMove(move);
    return YES;
}

- (void)commitPass {
    if (!_game || !_game->hasPositions()) return;
    _game->commitMove(Move::createPassMove());
}

- (void)commitExchangeWithTiles:(NSString *)tiles {
    if (!_game || !_game->hasPositions()) return;
    LetterString encodedTiles = QUACKLE_ALPHABET_PARAMETERS->encode(MARK_UV(nsToStd(tiles)));
    _game->commitMove(Move::createExchangeMove(encodedTiles, false));
}

#pragma mark - AI Play

- (nullable QBMoveInfo *)haveComputerPlay {
    if (!_game || !_game->hasPositions()) return nil;
    if (_game->currentPosition().gameOver()) return nil;

    // Get computer player
    ComputerPlayer *cp = _game->computerPlayer(_game->currentPosition().currentPlayer().id());
    if (!cp) return nil;

    // Generate candidate moves
    cp->setPosition(_game->currentPosition());
    MoveList moves = cp->moves(50);

    if (moves.empty()) return nil;

    // Check if NormalPlayer — apply Gaussian selection
    Move chosenMove = moves.front();
    NormalPlayer *np = dynamic_cast<NormalPlayer *>(cp);
    if (np && moves.size() > 1) {
        double bestEquity = moves.front().equity;
        double medianEquity = moves[moves.size() / 2].equity;
        double targetEquity = std::max(bestEquity - np->meanLoss(), medianEquity);
        double sd = np->stdDev();

        std::vector<double> weights;
        double sumWeights = 0.0;
        for (const auto &m : moves) {
            double diff = m.equity - targetEquity;
            double w = std::exp(-0.5 * (diff * diff) / (sd * sd));
            weights.push_back(w);
            sumWeights += w;
        }

        if (sumWeights > 0.0) {
            static std::mt19937 rng(static_cast<unsigned>(std::time(nullptr)));
            std::uniform_real_distribution<double> dist(0.0, sumWeights);
            double r = dist(rng);
            double cumulative = 0.0;
            for (size_t i = 0; i < moves.size(); ++i) {
                cumulative += weights[i];
                if (r <= cumulative) {
                    chosenMove = moves[i];
                    break;
                }
            }
        }
    }

    _game->commitMove(chosenMove);

    QBMoveInfo *info = [[QBMoveInfo alloc] init];
    info.moveDescription = uvToNS(chosenMove.toString());
    info.score = chosenMove.effectiveScore();
    info.equity = chosenMove.equity;
    info.moveType = (int)chosenMove.action;
    return info;
}

#pragma mark - History

- (int)historySize {
    if (!_game || !_game->hasPositions()) return 0;
    return (int)_game->history().size();
}

- (NSArray<QBHistoryEntry *> *)moveHistory {
    if (!_game || !_game->hasPositions()) return @[];

    NSMutableArray *result = [NSMutableArray array];
    const PlayerList &players = _game->history().players();

    // Track running totals per player
    std::map<int, int> totals;
    for (const auto &p : players) {
        totals[p.id()] = 0;
    }

    // Iterate through each player's positions
    for (const auto &player : players) {
        const PositionList positions = _game->history().positionsFacedBy(player.id());
        for (const auto &pos : positions) {
            const Move &move = pos.committedMove();
            if (move.action == Move::Nonmove) continue;

            int moveScore = move.effectiveScore();
            totals[player.id()] += moveScore;

            QBHistoryEntry *entry = [[QBHistoryEntry alloc] init];
            entry.turn = pos.turnNumber();
            entry.playerName = uvToNS(player.name());
            entry.moveDescription = uvToNS(move.toString());
            entry.score = moveScore;
            entry.totalScore = totals[player.id()];
            [result addObject:entry];
        }
    }

    // Sort by turn number
    [result sortUsingComparator:^NSComparisonResult(QBHistoryEntry *a, QBHistoryEntry *b) {
        if (a.turn != b.turn) return a.turn < b.turn ? NSOrderedAscending : NSOrderedDescending;
        return [a.playerName compare:b.playerName];
    }];

    return result;
}

@end
