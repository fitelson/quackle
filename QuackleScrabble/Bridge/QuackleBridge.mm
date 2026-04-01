#import "QuackleBridge.h"

#include <string>
#include <vector>
#include <iostream>
#include <random>
#include <ctime>
#include <cmath>
#include <stdexcept>

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
    _dataManager.setBackupLexicon("csw19");
    _dataManager.setAppDataDirectory(dataDir);
    // DataManager takes ownership of these heap-allocated objects and deletes them in its destructor
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

- (BOOL)initStage3LoadGaddag:(NSString *)lexicon {
    std::string lexName = nsToStd(lexicon);
    std::string gaddagFile = LexiconParameters::findDictionaryFile(lexName + ".gaddag");
    if (!gaddagFile.empty()) {
        _dataManager.lexiconParameters()->loadGaddag(gaddagFile);
        return YES;
    }
    NSLog(@"QuackleBridge: GADDAG file not found for %@ — move generation will be slower", lexicon);
    return NO;
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
    try {
        delete _game;  // safe if nullptr; frees previous Game and its owned Players/ComputerPlayers
        _game = new Game;

        PlayerList players;

        // Coin flip to determine who goes first
        bool humanFirst = arc4random_uniform(2) == 0;

        Player human(MARK_UV(nsToStd(name)), Player::HumanPlayerType, humanFirst ? 0 : 1);
        Player computer(MARK_UV("AI"), Player::ComputerPlayerType, humanFirst ? 1 : 0);
        // Player takes ownership of ComputerPlayer; deleted when Game is destroyed
        NormalPlayer *ai = new NormalPlayer(meanLoss, stdDev, MARK_UV("Intermediate"));
        computer.setComputerPlayer(ai);

        if (humanFirst) {
            players.push_back(human);
            players.push_back(computer);
        } else {
            players.push_back(computer);
            players.push_back(human);
        }

        _game->setPlayers(players);
        _game->associateKnownComputerPlayers();
        _game->addPosition();

        NSLog(@"QuackleBridge: New game started - %@ vs AI (NormalPlayer delta=%.1f sigma=%.1f) — %@ goes first",
              name, meanLoss, stdDev, humanFirst ? name : @"AI");
    } catch (const std::exception &e) {
        NSLog(@"QuackleBridge: C++ exception in startNewGame: %s", e.what());
    } catch (...) {
        NSLog(@"QuackleBridge: Unknown C++ exception in startNewGame");
    }
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

    try {
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
    } catch (const std::exception &e) {
        NSLog(@"QuackleBridge: C++ exception in kibitzMoves: %s", e.what());
        return @[];
    } catch (...) {
        NSLog(@"QuackleBridge: Unknown C++ exception in kibitzMoves");
        return @[];
    }
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

- (int)scoreMoveString:(NSString *)moveString {
    if (!_game || !_game->hasPositions()) return 0;

    std::string str = nsToStd(moveString);
    size_t spacePos = str.find(' ');
    if (spacePos == std::string::npos) return 0;

    std::string position = str.substr(0, spacePos);
    std::string word = str.substr(spacePos + 1);
    if (position.empty() || word.empty()) return 0;

    LetterString encodedWord = QUACKLE_ALPHABET_PARAMETERS->encode(MARK_UV(word));
    Move move = Move::createPlaceMove(MARK_UV(position), encodedWord);

    int validity = _game->currentPosition().validateMove(move);
    if (validity != 0) return 0;

    _game->currentPosition().scoreMove(move);
    return move.score;
}

- (int)scoreMoveStringIgnoringRack:(NSString *)moveString {
    if (!_game || !_game->hasPositions()) return 0;

    std::string str = nsToStd(moveString);
    size_t spacePos = str.find(' ');
    if (spacePos == std::string::npos) return 0;

    std::string position = str.substr(0, spacePos);
    std::string word = str.substr(spacePos + 1);
    if (position.empty() || word.empty()) return 0;

    LetterString encodedWord = QUACKLE_ALPHABET_PARAMETERS->encode(MARK_UV(word));
    Move move = Move::createPlaceMove(MARK_UV(position), encodedWord);

    // Ignore InvalidTiles (0x0001) — allow hypothetical moves with tiles not on rack
    int validity = _game->currentPosition().validateMove(move);
    if ((validity & ~0x0001) != 0) return 0;

    _game->currentPosition().scoreMove(move);
    return move.score;
}

- (BOOL)commitMoveString:(NSString *)moveString {
    if (!_game || !_game->hasPositions()) return NO;

    std::string str = nsToStd(moveString);
    size_t spacePos = str.find(' ');
    if (spacePos == std::string::npos) return NO;

    std::string position = str.substr(0, spacePos);
    std::string word = str.substr(spacePos + 1);
    if (position.empty() || word.empty()) return NO;

    try {
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
    } catch (const std::exception &e) {
        NSLog(@"QuackleBridge: C++ exception in commitMoveString: %s", e.what());
        return NO;
    } catch (...) {
        NSLog(@"QuackleBridge: Unknown C++ exception in commitMoveString");
        return NO;
    }
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

    try {
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
                static std::mt19937 rng(std::random_device{}());
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

        // Extract placed tile positions before committing
        NSMutableArray<QBTileInfo *> *placedTiles = [NSMutableArray array];
        if (chosenMove.action == Move::Place) {
            const LetterString &tiles = chosenMove.tiles();
            int row = chosenMove.startrow;
            int col = chosenMove.startcol;
            for (unsigned int i = 0; i < tiles.length(); ++i) {
                Letter letter = tiles[i];
                if (!Move::isAlreadyOnBoard(letter)) {
                    QBTileInfo *tile = [[QBTileInfo alloc] init];
                    tile.row = row;
                    tile.col = col;
                    tile.isBlank = QUACKLE_ALPHABET_PARAMETERS->isBlankLetter(letter);
                    Letter plain = QUACKLE_ALPHABET_PARAMETERS->clearBlankness(letter);
                    UVString vis = QUACKLE_ALPHABET_PARAMETERS->userVisible(plain);
                    tile.letter = uvToNS(vis);
                    tile.points = tile.isBlank ? 0 : QUACKLE_ALPHABET_PARAMETERS->letterParameter(plain).score();
                    [placedTiles addObject:tile];
                }
                if (chosenMove.horizontal) col++; else row++;
            }
        }

        _game->commitMove(chosenMove);

        QBMoveInfo *info = [[QBMoveInfo alloc] init];
        info.moveDescription = uvToNS(chosenMove.toString());
        info.score = chosenMove.effectiveScore();
        info.equity = chosenMove.equity;
        info.moveType = (int)chosenMove.action;
        info.placedTiles = placedTiles;
        return info;
    } catch (const std::exception &e) {
        NSLog(@"QuackleBridge: C++ exception in haveComputerPlay: %s", e.what());
        return nil;
    } catch (...) {
        NSLog(@"QuackleBridge: Unknown C++ exception in haveComputerPlay");
        return nil;
    }
}

#pragma mark - History

- (int)historySize {
    if (!_game || !_game->hasPositions()) return 0;
    return (int)_game->history().size();
}

- (NSArray<QBHistoryEntry *> *)moveHistory {
    if (!_game || !_game->hasPositions()) return @[];

    try {
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
    } catch (const std::exception &e) {
        NSLog(@"QuackleBridge: C++ exception in moveHistory: %s", e.what());
        return @[];
    } catch (...) {
        NSLog(@"QuackleBridge: Unknown C++ exception in moveHistory");
        return @[];
    }
}

- (int)currentPlayerIndex {
    if (!_game || !_game->hasPositions()) return 0;
    return _game->currentPosition().currentPlayer().id();
}

#pragma mark - Save/Restore

- (NSArray<NSString *> *)rackForPlayerIndex:(int)index {
    if (!_game || !_game->hasPositions()) return @[];
    const PlayerList &players = _game->currentPosition().players();
    if (index < 0 || index >= (int)players.size()) return @[];

    const Rack &rack = players[index].rack();
    LetterString tiles = rack.tiles();
    NSMutableArray *result = [NSMutableArray array];
    for (unsigned int i = 0; i < tiles.length(); ++i) {
        Letter letter = tiles[i];
        UVString str = QUACKLE_ALPHABET_PARAMETERS->userVisible(letter);
        [result addObject:uvToNS(str)];
    }
    return result;
}

- (NSArray<NSString *> *)bagTiles {
    if (!_game || !_game->hasPositions()) return @[];
    const Bag &bag = _game->currentPosition().bag();
    const LongLetterString &tiles = bag.tiles();
    NSMutableArray *result = [NSMutableArray array];
    for (unsigned int i = 0; i < tiles.size(); ++i) {
        Letter letter = tiles[i];
        UVString str = QUACKLE_ALPHABET_PARAMETERS->userVisible(letter);
        [result addObject:uvToNS(str)];
    }
    return result;
}

- (void)restoreGameWithHumanName:(NSString *)name
                      humanFirst:(BOOL)humanFirst
                      aiMeanLoss:(double)meanLoss
                        aiStdDev:(double)stdDev
                    boardLetters:(NSArray<NSArray<NSString *> *> *)boardLetters
                     boardBlanks:(NSArray<NSArray<NSNumber *> *> *)boardBlanks
                    playerScores:(NSArray<NSNumber *> *)scores
                     playerRacks:(NSArray<NSArray<NSString *> *> *)racks
                        bagTiles:(NSArray<NSString *> *)bagTileLetters
            currentPlayerIsHuman:(BOOL)humanTurn {
    try {
        delete _game;
        _game = new Game;

        // Set up players with saved scores
        PlayerList players;
        Player human(MARK_UV(nsToStd(name)), Player::HumanPlayerType, humanFirst ? 0 : 1);
        Player computer(MARK_UV("AI"), Player::ComputerPlayerType, humanFirst ? 1 : 0);
        NormalPlayer *ai = new NormalPlayer(meanLoss, stdDev, MARK_UV("Intermediate"));
        computer.setComputerPlayer(ai);

        int humanIdx = humanFirst ? 0 : 1;
        int aiIdx = humanFirst ? 1 : 0;
        if ((int)scores.count > humanIdx) human.setScore([scores[humanIdx] intValue]);
        if ((int)scores.count > aiIdx) computer.setScore([scores[aiIdx] intValue]);

        if (humanFirst) {
            players.push_back(human);
            players.push_back(computer);
        } else {
            players.push_back(computer);
            players.push_back(human);
        }

        _game->setPlayers(players);
        _game->associateKnownComputerPlayers();
        _game->addPosition();

        // Restore board by placing each tile
        Board board;
        board.prepareEmptyBoard();

        int rows = (int)boardLetters.count;
        for (int row = 0; row < rows; ++row) {
            NSArray<NSString *> *rowLetters = boardLetters[row];
            NSArray<NSNumber *> *rowBlanks = boardBlanks[row];
            if (![rowLetters isKindOfClass:[NSArray class]]) continue;
            int cols = (int)rowLetters.count;
            for (int col = 0; col < cols; ++col) {
                NSString *letter = rowLetters[col];
                if (![letter isKindOfClass:[NSString class]] || letter.length == 0) continue;

                BOOL isBlank = (col < (int)rowBlanks.count) ? [rowBlanks[col] boolValue] : NO;
                std::string letterStr;
                if (isBlank) {
                    letterStr = std::string(1, tolower([letter UTF8String][0]));
                } else {
                    letterStr = nsToStd(letter);
                }

                std::string pos = std::to_string(row + 1) + std::string(1, char('A' + col));
                LetterString encoded = QUACKLE_ALPHABET_PARAMETERS->encode(MARK_UV(letterStr));
                Move move = Move::createPlaceMove(MARK_UV(pos), encoded);
                board.makeMove(move);
            }
        }

        _game->currentPosition().setBoard(board);
        _game->currentPosition().ensureBoardIsPreparedForAnalysis();

        // Restore bag using LongLetterString (LetterString is fixed-length, max 40)
        LongLetterString bagLong;
        for (NSString *letter in bagTileLetters) {
            LetterString encoded = QUACKLE_ALPHABET_PARAMETERS->encode(MARK_UV(nsToStd(letter)));
            for (unsigned int i = 0; i < encoded.length(); ++i)
                bagLong += encoded[i];
        }
        Bag restoredBag;
        restoredBag.clear();  // default constructor fills with 100 tiles; must clear first
        restoredBag.toss(bagLong);
        _game->currentPosition().setBag(restoredBag);

        // Restore player racks
        for (int i = 0; i < (int)racks.count && i < (int)_game->currentPosition().players().size(); ++i) {
            NSArray<NSString *> *rackLetters = racks[i];
            LetterString rackTiles;
            for (NSString *letter in rackLetters) {
                LetterString encoded = QUACKLE_ALPHABET_PARAMETERS->encode(MARK_UV(nsToStd(letter)));
                rackTiles += encoded;
            }
            int playerId = _game->currentPosition().players()[i].id();
            _game->currentPosition().setPlayerRack(playerId, Rack(rackTiles), false);
        }

        // Set current player
        int humanId = humanFirst ? 0 : 1;
        int aiId = humanFirst ? 1 : 0;
        _game->currentPosition().setCurrentPlayer(humanTurn ? humanId : aiId);

        NSLog(@"QuackleBridge: Game restored — %@ vs AI, bag=%d tiles, %@ to play",
              name, (int)_game->currentPosition().bag().size(),
              humanTurn ? name : @"AI");
    } catch (const std::exception &e) {
        NSLog(@"QuackleBridge: C++ exception in restoreGame: %s", e.what());
    } catch (...) {
        NSLog(@"QuackleBridge: Unknown C++ exception in restoreGame");
    }
}

#pragma mark - Multiplayer (Two Human Players)

- (void)startNewTwoHumanGameWithPlayer1:(NSString *)name1
                                player2:(NSString *)name2 {
    try {
        delete _game;
        _game = new Game;

        PlayerList players;
        Player p1(MARK_UV(nsToStd(name1)), Player::HumanPlayerType, 0);
        Player p2(MARK_UV(nsToStd(name2)), Player::HumanPlayerType, 1);
        players.push_back(p1);
        players.push_back(p2);

        _game->setPlayers(players);
        _game->addPosition();

        NSLog(@"QuackleBridge: New two-human game started — %@ vs %@", name1, name2);
    } catch (const std::exception &e) {
        NSLog(@"QuackleBridge: C++ exception in startNewTwoHumanGame: %s", e.what());
    } catch (...) {
        NSLog(@"QuackleBridge: Unknown C++ exception in startNewTwoHumanGame");
    }
}

- (void)restoreTwoHumanGameWithPlayer1:(NSString *)name1
                               player2:(NSString *)name2
                          boardLetters:(NSArray<NSArray<NSString *> *> *)boardLetters
                           boardBlanks:(NSArray<NSArray<NSNumber *> *> *)boardBlanks
                          playerScores:(NSArray<NSNumber *> *)scores
                           playerRacks:(NSArray<NSArray<NSString *> *> *)racks
                              bagTiles:(NSArray<NSString *> *)bagTileLetters
                    currentPlayerIndex:(int)currentIdx {
    try {
        delete _game;
        _game = new Game;

        PlayerList players;
        Player p1(MARK_UV(nsToStd(name1)), Player::HumanPlayerType, 0);
        Player p2(MARK_UV(nsToStd(name2)), Player::HumanPlayerType, 1);

        if ((int)scores.count > 0) p1.setScore([scores[0] intValue]);
        if ((int)scores.count > 1) p2.setScore([scores[1] intValue]);

        players.push_back(p1);
        players.push_back(p2);

        _game->setPlayers(players);
        _game->addPosition();

        // Restore board
        Board board;
        board.prepareEmptyBoard();

        int rows = (int)boardLetters.count;
        for (int row = 0; row < rows; ++row) {
            NSArray<NSString *> *rowLetters = boardLetters[row];
            NSArray<NSNumber *> *rowBlanks = boardBlanks[row];
            if (![rowLetters isKindOfClass:[NSArray class]]) continue;
            int cols = (int)rowLetters.count;
            for (int col = 0; col < cols; ++col) {
                NSString *letter = rowLetters[col];
                if (![letter isKindOfClass:[NSString class]] || letter.length == 0) continue;

                BOOL isBlank = (col < (int)rowBlanks.count) ? [rowBlanks[col] boolValue] : NO;
                std::string letterStr;
                if (isBlank) {
                    letterStr = std::string(1, tolower([letter UTF8String][0]));
                } else {
                    letterStr = nsToStd(letter);
                }

                std::string pos = std::to_string(row + 1) + std::string(1, char('A' + col));
                LetterString encoded = QUACKLE_ALPHABET_PARAMETERS->encode(MARK_UV(letterStr));
                Move move = Move::createPlaceMove(MARK_UV(pos), encoded);
                board.makeMove(move);
            }
        }

        _game->currentPosition().setBoard(board);
        _game->currentPosition().ensureBoardIsPreparedForAnalysis();

        // Restore bag
        LongLetterString bagLong;
        for (NSString *letter in bagTileLetters) {
            LetterString encoded = QUACKLE_ALPHABET_PARAMETERS->encode(MARK_UV(nsToStd(letter)));
            for (unsigned int i = 0; i < encoded.length(); ++i)
                bagLong += encoded[i];
        }
        Bag restoredBag;
        restoredBag.clear();
        restoredBag.toss(bagLong);
        _game->currentPosition().setBag(restoredBag);

        // Restore player racks
        for (int i = 0; i < (int)racks.count && i < (int)_game->currentPosition().players().size(); ++i) {
            NSArray<NSString *> *rackLetters = racks[i];
            LetterString rackTiles;
            for (NSString *letter in rackLetters) {
                LetterString encoded = QUACKLE_ALPHABET_PARAMETERS->encode(MARK_UV(nsToStd(letter)));
                rackTiles += encoded;
            }
            int playerId = _game->currentPosition().players()[i].id();
            _game->currentPosition().setPlayerRack(playerId, Rack(rackTiles), false);
        }

        // Set current player
        _game->currentPosition().setCurrentPlayer(currentIdx);

        NSLog(@"QuackleBridge: Two-human game restored — %@ vs %@, bag=%d tiles, player %d to play",
              name1, name2, (int)_game->currentPosition().bag().size(), currentIdx);
    } catch (const std::exception &e) {
        NSLog(@"QuackleBridge: C++ exception in restoreTwoHumanGame: %s", e.what());
    } catch (...) {
        NSLog(@"QuackleBridge: Unknown C++ exception in restoreTwoHumanGame");
    }
}

@end
