#import "QuackleBridge.h"

#include <string>
#include <vector>
#include <iostream>
#include <random>
#include <ctime>
#include <cmath>
#include <stdexcept>
#include <map>

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

// Helper: UVString to NSString. stringWithUTF8String: returns nil on invalid UTF-8;
// never hand nil back (callers insert into NSArrays / honor a nonnull contract).
static NSString *uvToNS(const UVString &s) {
    NSString *r = [NSString stringWithUTF8String:s.c_str()];
    return r ?: @"";
}

// Helper: NSString to std::string. -[NSString UTF8String] can return NULL; guard it
// (std::string(NULL) is undefined behavior).
static std::string nsToStd(NSString *s) {
    const char *c = s.UTF8String;
    return c ? std::string(c) : std::string();
}

// --- AI bingo vocabulary (draw-probability model, per word length) ---
// A bingo always lays 7 tiles, but played THROUGH existing board tiles it can form a word
// of length 7..15. We score the FULL word's draw-probability
// logCount = Σ ln C(bagCount[L], timesUsed[L]) over ALL its letters (drawLogCount), then
// "know" it iff logCount sits in the top `bingoKnowledge` fraction of CSW19 words OF THE
// SAME LENGTH — i.e. logCount >= the (1 - bingoKnowledge) quantile for that length. So the
// slider tracks TRUE frequency at every length (an obscure 8-letter word is judged against
// 8-letter words, not credited just because its 7 drawn tiles are common). Deterministic
// and nested (raising the slider only adds words). Blanks score as the letter they spell.
//
// kBingoQuantile[len][i] = the (5*i)th percentile of lnDrawCount over the CSW19 words of
// that length (extracted by walking the bundled data/lexica/csw19.dawg; words needing a
// blank to draw are excluded). Rows 0..6 duplicate row 7 and are never used (bingos ≥ 7).
// Regenerate with tools/bingo_calib.py if the lexicon changes. Sanity: REGIONS (7, ln
// 12.83) → ~98th pct; NOTARIES (8) → 100th; TZADDIQS (8) → ~9th.
static const double kBingoQuantile[16][21] = {
    {  1.3863,  7.6779,  8.2657,  8.7232,  9.0766,  9.2828,  9.5649,  9.8218,  9.9396, 10.2273, 10.3451, 10.5682, 10.6635, 10.9205, 11.0382, 11.2614, 11.4437, 11.7032, 11.9545, 12.3600, 14.3341 },  // 0->7
    {  1.3863,  7.6779,  8.2657,  8.7232,  9.0766,  9.2828,  9.5649,  9.8218,  9.9396, 10.2273, 10.3451, 10.5682, 10.6635, 10.9205, 11.0382, 11.2614, 11.4437, 11.7032, 11.9545, 12.3600, 14.3341 },  // 1->7
    {  1.3863,  7.6779,  8.2657,  8.7232,  9.0766,  9.2828,  9.5649,  9.8218,  9.9396, 10.2273, 10.3451, 10.5682, 10.6635, 10.9205, 11.0382, 11.2614, 11.4437, 11.7032, 11.9545, 12.3600, 14.3341 },  // 2->7
    {  1.3863,  7.6779,  8.2657,  8.7232,  9.0766,  9.2828,  9.5649,  9.8218,  9.9396, 10.2273, 10.3451, 10.5682, 10.6635, 10.9205, 11.0382, 11.2614, 11.4437, 11.7032, 11.9545, 12.3600, 14.3341 },  // 3->7
    {  1.3863,  7.6779,  8.2657,  8.7232,  9.0766,  9.2828,  9.5649,  9.8218,  9.9396, 10.2273, 10.3451, 10.5682, 10.6635, 10.9205, 11.0382, 11.2614, 11.4437, 11.7032, 11.9545, 12.3600, 14.3341 },  // 4->7
    {  1.3863,  7.6779,  8.2657,  8.7232,  9.0766,  9.2828,  9.5649,  9.8218,  9.9396, 10.2273, 10.3451, 10.5682, 10.6635, 10.9205, 11.0382, 11.2614, 11.4437, 11.7032, 11.9545, 12.3600, 14.3341 },  // 5->7
    {  1.3863,  7.6779,  8.2657,  8.7232,  9.0766,  9.2828,  9.5649,  9.8218,  9.9396, 10.2273, 10.3451, 10.5682, 10.6635, 10.9205, 11.0382, 11.2614, 11.4437, 11.7032, 11.9545, 12.3600, 14.3341 },  // 6->7
    {  1.3863,  7.6779,  8.2657,  8.7232,  9.0766,  9.2828,  9.5649,  9.8218,  9.9396, 10.2273, 10.3451, 10.5682, 10.6635, 10.9205, 11.0382, 11.2614, 11.4437, 11.7032, 11.9545, 12.3600, 14.3341 },  // 7
    {  2.7081,  8.8410,  9.5342,  9.9396, 10.3451, 10.6328, 10.9205, 11.0746, 11.3259, 11.5491, 11.7314, 11.9321, 12.0723, 12.2910, 12.4245, 12.6784, 12.8300, 13.1177, 13.4361, 13.8108, 15.7204 },  // 8
    {  3.5835, 10.0292, 10.7869, 11.3102, 11.6444, 11.9545, 12.1732, 12.4245, 12.7122, 12.8483, 13.1177, 13.2538, 13.4725, 13.6593, 13.8416, 14.0828, 14.2527, 14.5347, 14.8449, 15.2687, 17.1067 },  // 9
    {  4.7875, 11.1560, 11.9729, 12.4245, 12.8300, 13.1540, 13.4586, 13.7238, 13.9470, 14.1701, 14.3704, 14.5936, 14.7917, 14.9923, 15.1971, 15.4203, 15.6334, 15.9210, 16.2087, 16.7012, 18.8114 },  // 10
    {  5.6630, 12.1552, 13.0531, 13.5823, 14.0115, 14.3524, 14.6218, 14.8813, 15.1326, 15.3513, 15.6026, 15.8257, 16.0264, 16.2312, 16.4499, 16.7012, 16.9243, 17.2244, 17.5305, 18.0230, 20.1977 },  // 11
    {  6.1862, 13.0895, 13.9650, 14.6218, 15.0456, 15.4203, 15.7387, 16.0081, 16.2620, 16.5189, 16.7320, 16.9607, 17.2120, 17.4127, 17.6483, 17.9052, 18.1771, 18.4648, 18.7806, 19.3222, 21.5840 },  // 12
    {  5.6630, 14.0340, 14.9766, 15.5928, 16.0752, 16.4499, 16.7683, 17.0785, 17.3482, 17.6175, 17.8406, 18.0875, 18.3290, 18.5826, 18.8215, 19.0867, 19.3403, 19.6587, 20.0334, 20.5724, 22.9703 },  // 13
    {  9.6519, 14.8633, 15.8033, 16.4499, 16.9427, 17.3786, 17.7536, 18.0593, 18.3594, 18.6471, 18.9168, 19.1579, 19.4119, 19.6587, 19.9201, 20.1977, 20.4854, 20.8319, 21.2194, 21.7426, 23.8866 },  // 14
    {  8.8410, 15.8257, 16.7195, 17.3969, 17.9258, 18.3313, 18.7161, 19.0526, 19.3403, 19.6099, 19.8819, 20.1512, 20.4209, 20.6804, 20.9497, 21.2374, 21.5558, 21.8923, 22.3180, 22.8288, 24.8674 },  // 15
};

// lnDrawCount at the p-th percentile for words of the given length; linear interp over the
// 5%-spaced grid. Length clamped to the 7..15 bingo range.
static double bingoLnQuantile(int len, double p) {
    if (len < 7) len = 7; else if (len > 15) len = 15;
    const double *q = kBingoQuantile[len];
    if (p <= 0.0) return q[0];
    if (p >= 1.0) return q[20];
    double x = p * 20.0;
    int i = (int)x;
    if (i >= 20) return q[20];
    return q[i] + (x - i) * (q[i + 1] - q[i]);
}

static double lnChoose(int n, int k) {
    if (k <= 0) return 0.0;
    if (k > n) return -INFINITY;  // can't draw more of a tile than exist in the bag
    double r = 0.0;
    for (int i = 0; i < k; ++i)
        r += std::log((double)(n - i)) - std::log((double)(i + 1));
    return r;
}

// Σ ln C(bagCount, timesUsed) over a full word's letters (plain). Higher = more probable.
static double drawLogCount(const LetterString &word) {
    std::map<Letter, int> counts;
    for (unsigned int i = 0; i < word.length(); ++i) counts[word[i]]++;
    double logCount = 0.0;
    for (const auto &kv : counts)
        logCount += lnChoose(QUACKLE_ALPHABET_PARAMETERS->count(kv.first), kv.second);
    return logCount;
}

// The full word a Place move forms, as plain letters: laid tiles plus the board tiles it
// plays through (resolved from the board, blankness cleared).
static LetterString bingoFullWord(const Move &m, const Board &board) {
    LetterString word;
    int r = m.startrow, c = m.startcol;
    const LetterString &t = m.tiles();
    for (unsigned int i = 0; i < t.length(); ++i) {
        Letter L = Move::isAlreadyOnBoard(t[i]) ? board.letter(r, c) : t[i];
        word += QUACKLE_ALPHABET_PARAMETERS->clearBlankness(L);
        if (m.horizontal) ++c; else ++r;
    }
    return word;
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
    Letter letter = board.letter(row, col);
    // Treat both the empty mark and the played-thru mark (".", byte 2) as empty. A
    // played-thru mark is never a real tile; surfacing it as a "." cell would let it
    // round-trip into the saved board and corrupt the game.
    if (letter == QUACKLE_NULL_MARK || !QUACKLE_ALPHABET_PARAMETERS->isSomeLetter(letter)) return @"";

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
    Letter letter = _game->currentPosition().board().letter(row, col);
    // A played-thru mark (".", byte 2) is not a real tile — report it as vacant so it
    // never reaches the model board, the display, or the saved game.
    return letter == QUACKLE_NULL_MARK || !QUACKLE_ALPHABET_PARAMETERS->isSomeLetter(letter);
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

- (int)finalScoreForPlayerIndex:(int)index {
    if (!_game || !_game->hasPositions()) return 0;
    try {
        const GamePosition &pos = _game->currentPosition();
        if (index < 0 || index >= (int)pos.players().size()) return 0;
        // endgameAdjustedScores() UNCONDITIONALLY adds m_moveMade.effectiveScore() to
        // the current player when gameOver(). That is only correct on a LIVE game over,
        // where the staged move is the real UnusedTilesBonus. After a RESTORE the staged
        // move is a Nonmove (effectiveScore -9999) — and we already persisted the
        // adjusted score into the raw score at save/export time — so trust the
        // adjustment ONLY for a genuine unused-tiles bonus; otherwise return raw.
        if (pos.gameOver() && pos.moveMade().action != Move::UnusedTilesBonus) {
            return pos.players()[index].score();
        }
        PlayerList adjusted = pos.endgameAdjustedScores();
        if (index < 0 || index >= (int)adjusted.size()) return 0;
        return adjusted[index].score();
    } catch (const std::exception &e) {
        NSLog(@"QuackleBridge: C++ exception in finalScoreForPlayerIndex: %s", e.what());
        return [self scoreForPlayerIndex:index];
    } catch (...) {
        return [self scoreForPlayerIndex:index];
    }
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

- (int)scorelessTurns {
    if (!_game || !_game->hasPositions()) return 0;
    return _game->currentPosition().scorelessTurnsInARow();
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

    try {
        LetterString encodedWord = QUACKLE_ALPHABET_PARAMETERS->encode(MARK_UV(word));
        Move move = Move::createPlaceMove(MARK_UV(position), encodedWord);
        int result = _game->currentPosition().validateMove(move);
        NSLog(@"QuackleBridge: validateMove result=%d", result);
        return result;
    } catch (const std::exception &e) {
        NSLog(@"QuackleBridge: C++ exception in validateMoveString: %s", e.what());
        return -1;
    } catch (...) {
        return -1;
    }
}

- (int)scoreMoveString:(NSString *)moveString {
    if (!_game || !_game->hasPositions()) return 0;

    std::string str = nsToStd(moveString);
    size_t spacePos = str.find(' ');
    if (spacePos == std::string::npos) return 0;

    std::string position = str.substr(0, spacePos);
    std::string word = str.substr(spacePos + 1);
    if (position.empty() || word.empty()) return 0;

    try {
        LetterString encodedWord = QUACKLE_ALPHABET_PARAMETERS->encode(MARK_UV(word));
        Move move = Move::createPlaceMove(MARK_UV(position), encodedWord);
        int validity = _game->currentPosition().validateMove(move);
        if (validity != 0) return 0;
        _game->currentPosition().scoreMove(move);
        return move.score;
    } catch (const std::exception &e) {
        NSLog(@"QuackleBridge: C++ exception in scoreMoveString: %s", e.what());
        return 0;
    } catch (...) {
        return 0;
    }
}

- (int)scoreMoveStringIgnoringRack:(NSString *)moveString {
    if (!_game || !_game->hasPositions()) return 0;

    std::string str = nsToStd(moveString);
    size_t spacePos = str.find(' ');
    if (spacePos == std::string::npos) return 0;

    std::string position = str.substr(0, spacePos);
    std::string word = str.substr(spacePos + 1);
    if (position.empty() || word.empty()) return 0;

    try {
        LetterString encodedWord = QUACKLE_ALPHABET_PARAMETERS->encode(MARK_UV(word));
        Move move = Move::createPlaceMove(MARK_UV(position), encodedWord);
        // Ignore InvalidTiles (0x0001) — allow hypothetical moves with tiles not on rack
        int validity = _game->currentPosition().validateMove(move);
        if ((validity & ~0x0001) != 0) return 0;
        _game->currentPosition().scoreMove(move);
        return move.score;
    } catch (const std::exception &e) {
        NSLog(@"QuackleBridge: C++ exception in scoreMoveStringIgnoringRack: %s", e.what());
        return 0;
    } catch (...) {
        return 0;
    }
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

- (BOOL)commitPass {
    if (!_game || !_game->hasPositions()) return NO;
    try {
        _game->commitMove(Move::createPassMove());
        return YES;
    } catch (const std::exception &e) {
        NSLog(@"QuackleBridge: C++ exception in commitPass: %s", e.what());
    } catch (...) {
        NSLog(@"QuackleBridge: Unknown C++ exception in commitPass");
    }
    return NO;
}

- (BOOL)commitExchangeWithTiles:(NSString *)tiles {
    if (!_game || !_game->hasPositions()) return NO;
    try {
        // Rules: cannot exchange unless at least a full rack (7) remains in the bag.
        static const int kFullRack = 7;
        if ((int)_game->currentPosition().bag().size() < kFullRack) {
            NSLog(@"QuackleBridge: refusing exchange — fewer than a full rack in the bag");
            return NO;
        }
        LetterString encodedTiles = QUACKLE_ALPHABET_PARAMETERS->encode(MARK_UV(nsToStd(tiles)));
        _game->commitMove(Move::createExchangeMove(encodedTiles, false));
        return YES;
    } catch (const std::exception &e) {
        NSLog(@"QuackleBridge: C++ exception in commitExchangeWithTiles: %s", e.what());
    } catch (...) {
        NSLog(@"QuackleBridge: Unknown C++ exception in commitExchangeWithTiles");
    }
    return NO;
}

#pragma mark - AI Play

- (nullable QBMoveInfo *)haveComputerPlayWithBingoKnowledge:(double)bingoKnowledge {
    if (!_game || !_game->hasPositions()) return nil;
    if (_game->currentPosition().gameOver()) return nil;
    // Never let the engine play on a human's behalf. computerPlayer(id) falls back
    // to a default StaticPlayer when the current id has no computer player, so guard
    // on the player TYPE — a stale/double trigger that fires after the turn returned
    // to the human must be a no-op, not a move committed for them.
    if (_game->currentPosition().currentPlayer().type() != Player::ComputerPlayerType) return nil;

    try {
        // Get computer player
        ComputerPlayer *cp = _game->computerPlayer(_game->currentPosition().currentPlayer().id());
        if (!cp) return nil;

        // Generate candidate moves
        cp->setPosition(_game->currentPosition());
        MoveList moves = cp->moves(100);

        if (moves.empty()) return nil;

        static std::mt19937 rng(std::random_device{}());

        // Bingo = a Place move that lays all 7 rack tiles.
        auto isBingoMove = [](const Move &m) -> bool {
            if (m.action != Move::Place) return false;
            int laid = 0;
            const LetterString &t = m.tiles();
            for (unsigned int i = 0; i < t.length(); ++i) {
                if (!Move::isAlreadyOnBoard(t[i])) laid++;
            }
            return laid == 7;
        };

        // Hide bingos the AI "doesn't know". Familiarity tracks each bingo's
        // draw-probability (bingoDrawLogCount): common-letter racks are known first,
        // rare-tile racks last. Deterministic per rack and nested in the slider value
        // (raising it only adds words), so the AI's vocabulary is stable across turns.
        const Board &board = _game->currentPosition().board();
        auto knownBingo = [&board](const Move &m, double knowledge) -> bool {
            double clamped = std::max(0.0, std::min(1.0, knowledge));
            if (clamped <= 0.0) return false;
            if (clamped >= 1.0) return true;
            // Score the FULL word (laid + played-thru letters) against CSW19 words of the
            // SAME length, so 8+ letter through-plays are judged as the rarer words they
            // are. Known iff in the top `clamped` fraction at that length.
            LetterString word = bingoFullWord(m, board);
            return drawLogCount(word) >= bingoLnQuantile((int)word.length(), 1.0 - clamped);
        };

        std::vector<size_t> pool;
        for (size_t i = 0; i < moves.size(); ++i) {
            if (!isBingoMove(moves[i]) || knownBingo(moves[i], bingoKnowledge)) {
                pool.push_back(i);
            }
        }
        if (pool.empty()) {
            for (size_t i = 0; i < moves.size(); ++i) {
                pool.push_back(i);
            }
        }

        // Apply Gaussian selection over the chosen pool (NormalPlayer only).
        Move chosenMove = moves[pool.front()];
        NormalPlayer *np = dynamic_cast<NormalPlayer *>(cp);
        if (np && pool.size() > 1) {
            double bestEquity = moves[pool.front()].equity;
            double medianEquity = moves[pool[pool.size() / 2]].equity;
            double targetEquity = std::max(bestEquity - np->meanLoss(), medianEquity);
            double sd = np->stdDev();

            std::vector<double> weights;
            double sumWeights = 0.0;
            for (size_t idx : pool) {
                double diff = moves[idx].equity - targetEquity;
                double w = std::exp(-0.5 * (diff * diff) / (sd * sd));
                weights.push_back(w);
                sumWeights += w;
            }

            if (sumWeights > 0.0) {
                std::uniform_real_distribution<double> dist(0.0, sumWeights);
                double r = dist(rng);
                double cumulative = 0.0;
                for (size_t i = 0; i < pool.size(); ++i) {
                    cumulative += weights[i];
                    if (r <= cumulative) {
                        chosenMove = moves[pool[i]];
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
                entry.playerIndex = player.id();
                entry.playerName = uvToNS(player.name());
                // An exchange is hidden information: never reveal WHICH tiles were
                // swapped (move.toString() would be e.g. "-AIIPU"). Show only the count,
                // matching real Scrabble — and avoiding leaking a player's rack into the
                // (serialized, cross-device) multiplayer history.
                if (move.action == Move::Exchange || move.action == Move::BlindExchange) {
                    int n = (int)move.tiles().length();
                    entry.moveDescription = [NSString stringWithFormat:@"Exchanged %d tile%@", n, (n == 1 ? @"" : @"s")];
                } else {
                    entry.moveDescription = uvToNS(move.toString());
                }
                entry.score = moveScore;
                entry.totalScore = totals[player.id()];
                [result addObject:entry];
            }
        }

        // Sort by turn number, then by player index (stable, name-collision-proof)
        [result sortUsingComparator:^NSComparisonResult(QBHistoryEntry *a, QBHistoryEntry *b) {
            if (a.turn != b.turn) return a.turn < b.turn ? NSOrderedAscending : NSOrderedDescending;
            if (a.playerIndex != b.playerIndex) return a.playerIndex < b.playerIndex ? NSOrderedAscending : NSOrderedDescending;
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
            currentPlayerIsHuman:(BOOL)humanTurn
                  scorelessTurns:(int)scorelessTurns
               currentTurnNumber:(int)turnNumber
                        gameOver:(BOOL)gameOver {
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

        // Set the SCALAR position fields FIRST (before the fault-prone board work), so
        // that if board prep ever throws, bag/turn/scores stay consistent with the saved
        // game instead of the fresh values addPosition() seeded (bag=86, turn=1).
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

        int humanId = humanFirst ? 0 : 1;
        int aiId = humanFirst ? 1 : 0;
        _game->currentPosition().setCurrentPlayer(humanTurn ? humanId : aiId);
        if (turnNumber > 0) _game->currentPosition().setTurnNumber(turnNumber);
        _game->currentPosition().setScorelessTurnsInARow(scorelessTurns);
        _game->currentPosition().setGameOver(gameOver);

        // Restore board LAST by placing each tile (this + ensureBoardIsPreparedForAnalysis
        // is the fault-prone part — it walks the GADDAG, which may be absent).
        Board board;
        board.prepareEmptyBoard();

        int rows = (int)boardLetters.count;
        for (int row = 0; row < rows; ++row) {
            NSArray<NSString *> *rowLetters = boardLetters[row];
            if (row >= (int)boardBlanks.count) continue;  // mismatched arrays → skip row
            NSArray<NSNumber *> *rowBlanks = boardBlanks[row];
            if (![rowLetters isKindOfClass:[NSArray class]]) continue;
            int cols = (int)rowLetters.count;
            for (int col = 0; col < cols; ++col) {
                NSString *letter = rowLetters[col];
                if (![letter isKindOfClass:[NSString class]] || letter.length == 0) continue;

                BOOL isBlank = (col < (int)rowBlanks.count) ? [rowBlanks[col] boolValue] : NO;
                std::string letterStr;
                if (isBlank) {
                    letterStr = std::string(1, (char)tolower((unsigned char)[letter UTF8String][0]));
                } else {
                    letterStr = nsToStd(letter);
                }

                LetterString encoded = QUACKLE_ALPHABET_PARAMETERS->encode(MARK_UV(letterStr));
                // CRITICAL: only place a single REAL letter. A saved "." (the played-thru
                // mark, byte 2) encodes to a non-letter and must NOT be written as a tile —
                // otherwise it round-trips as a literal "." board tile and corrupts the game.
                if (encoded.length() != 1 || !QUACKLE_ALPHABET_PARAMETERS->isSomeLetter(encoded[0])) continue;

                std::string pos = std::to_string(row + 1) + std::string(1, char('A' + col));
                Move move = Move::createPlaceMove(MARK_UV(pos), encoded);
                board.makeMove(move);
            }
        }

        _game->currentPosition().setBoard(board);
        _game->currentPosition().ensureBoardIsPreparedForAnalysis();

        // CRITICAL: addPosition() recorded the history's currentLocation = (player, turn)
        // BEFORE we applied the saved currentPlayer + turnNumber. A GamePosition's location
        // is (currentPlayer().id(), turnNumber()), so those setters moved this position's
        // location while currentLocation stayed stale. The next commitMove() does
        // addClonePosition() → eraseAfter(currentLocation), which would erase THIS position
        // (its location now sorts after the stale one) and leave the list empty → a FRESH
        // GamePosition (bag=86, turn=1, empty board): the whole restored board vanishes on
        // the first move. Re-sync currentLocation so commit clones this position instead.
        _game->setCurrentPosition(_game->currentPosition().location());

        NSLog(@"QuackleBridge: Game restored — %@ vs AI, bag=%d tiles, %@ to play, scoreless=%d, gameOver=%@",
              name, (int)_game->currentPosition().bag().size(),
              humanTurn ? name : @"AI", scorelessTurns, gameOver ? @"YES" : @"NO");
    } catch (const std::exception &e) {
        NSLog(@"QuackleBridge: C++ exception in restoreGame: %s — discarding partial game", e.what());
        delete _game; _game = nullptr;  // fail closed: never leave a half-restored game
    } catch (...) {
        NSLog(@"QuackleBridge: Unknown C++ exception in restoreGame — discarding partial game");
        delete _game; _game = nullptr;
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
                    currentPlayerIndex:(int)currentIdx
                      currentTurnNumber:(int)turnNumber
                         scorelessTurns:(int)scorelessTurns
                               gameOver:(BOOL)gameOver {
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

        // Set the SCALAR position fields FIRST (before the fault-prone board work), so
        // that if board prep throws, bag/turn/scores stay consistent with the saved game
        // instead of the fresh values addPosition() seeded.
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

        _game->currentPosition().setCurrentPlayer(currentIdx);
        _game->currentPosition().setTurnNumber(turnNumber);
        _game->currentPosition().setScorelessTurnsInARow(scorelessTurns);
        _game->currentPosition().setGameOver(gameOver);

        // Restore board LAST (fault-prone — placeMove + ensureBoardIsPreparedForAnalysis).
        Board board;
        board.prepareEmptyBoard();

        int rows = (int)boardLetters.count;
        for (int row = 0; row < rows; ++row) {
            NSArray<NSString *> *rowLetters = boardLetters[row];
            if (row >= (int)boardBlanks.count) continue;  // mismatched arrays → skip row
            NSArray<NSNumber *> *rowBlanks = boardBlanks[row];
            if (![rowLetters isKindOfClass:[NSArray class]]) continue;
            int cols = (int)rowLetters.count;
            for (int col = 0; col < cols; ++col) {
                NSString *letter = rowLetters[col];
                if (![letter isKindOfClass:[NSString class]] || letter.length == 0) continue;

                BOOL isBlank = (col < (int)rowBlanks.count) ? [rowBlanks[col] boolValue] : NO;
                std::string letterStr;
                if (isBlank) {
                    letterStr = std::string(1, (char)tolower((unsigned char)[letter UTF8String][0]));
                } else {
                    letterStr = nsToStd(letter);
                }

                LetterString encoded = QUACKLE_ALPHABET_PARAMETERS->encode(MARK_UV(letterStr));
                // CRITICAL: only place a single REAL letter — never a saved "." (played-thru
                // mark, byte 2), which would round-trip as a literal board tile and corrupt
                // the game. See restoreGameWithHumanName: for the full rationale.
                if (encoded.length() != 1 || !QUACKLE_ALPHABET_PARAMETERS->isSomeLetter(encoded[0])) continue;

                std::string pos = std::to_string(row + 1) + std::string(1, char('A' + col));
                Move move = Move::createPlaceMove(MARK_UV(pos), encoded);
                board.makeMove(move);
            }
        }

        _game->currentPosition().setBoard(board);
        _game->currentPosition().ensureBoardIsPreparedForAnalysis();

        // See restoreGameWithHumanName: — re-sync currentLocation after setCurrentPlayer/
        // setTurnNumber so the next commit clones this position instead of wiping it.
        _game->setCurrentPosition(_game->currentPosition().location());

        NSLog(@"QuackleBridge: Two-human game restored — %@ vs %@, bag=%d tiles, player %d turn %d, scoreless=%d, gameOver=%@",
              name1, name2, (int)_game->currentPosition().bag().size(), currentIdx,
              turnNumber, scorelessTurns, gameOver ? @"YES" : @"NO");
    } catch (const std::exception &e) {
        NSLog(@"QuackleBridge: C++ exception in restoreTwoHumanGame: %s — discarding partial game", e.what());
        delete _game; _game = nullptr;  // fail closed: never leave a half-restored game
    } catch (...) {
        NSLog(@"QuackleBridge: Unknown C++ exception in restoreTwoHumanGame — discarding partial game");
        delete _game; _game = nullptr;
    }
}

@end
