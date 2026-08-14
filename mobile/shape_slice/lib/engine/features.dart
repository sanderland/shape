// Port of KataGo's katago/game/features.py (fill_row_features + iterLadders)
// and the GameState wrapper that owns board history.
//
// Output layout matches the exported ONNX: bin_input is NCHW, index
// c * posLen * posLen + (y * posLen + x); global_input is 19 wide.

import 'dart:typed_data';

import 'board.dart';

const int kNumBinFeatures = 22;
const int kNumGlobalFeatures = 19;

class Rules {
  final String koRule; // KO_SIMPLE | KO_POSITIONAL | KO_SITUATIONAL | KO_SPIGHT
  final String scoringRule; // SCORING_AREA | SCORING_TERRITORY
  final String taxRule; // TAX_NONE | TAX_SEKI | TAX_ALL
  final bool multiStoneSuicideLegal;
  final bool hasButton;
  final int encorePhase;
  final bool passWouldEndPhase;
  final double whiteKomi;
  final double asymPowersOfTwo;

  const Rules({
    required this.koRule,
    required this.scoringRule,
    required this.taxRule,
    required this.multiStoneSuicideLegal,
    this.hasButton = false,
    this.encorePhase = 0,
    this.passWouldEndPhase = false,
    required this.whiteKomi,
    this.asymPowersOfTwo = 0.0,
  });

  Rules withKomi(double komi) => Rules(
        koRule: koRule,
        scoringRule: scoringRule,
        taxRule: taxRule,
        multiStoneSuicideLegal: multiStoneSuicideLegal,
        hasButton: hasButton,
        encorePhase: encorePhase,
        passWouldEndPhase: passWouldEndPhase,
        whiteKomi: komi,
        asymPowersOfTwo: asymPowersOfTwo,
      );

  static const japanese = Rules(
    koRule: 'KO_SIMPLE',
    scoringRule: 'SCORING_TERRITORY',
    taxRule: 'TAX_SEKI',
    multiStoneSuicideLegal: false,
    whiteKomi: 6.5,
  );

  static const chinese = Rules(
    koRule: 'KO_SIMPLE',
    scoringRule: 'SCORING_AREA',
    taxRule: 'TAX_NONE',
    multiStoneSuicideLegal: false,
    whiteKomi: 7.5,
  );

  static const trompTaylor = Rules(
    koRule: 'KO_POSITIONAL',
    scoringRule: 'SCORING_AREA',
    taxRule: 'TAX_NONE',
    multiStoneSuicideLegal: true,
    whiteKomi: 7.5,
  );

  /// SGF `RU` values, as SHAPE writes them.
  static Rules fromName(String name) {
    switch (name.toLowerCase()) {
      case 'jp':
      case 'japanese':
        return japanese;
      case 'cn':
      case 'chinese':
        return chinese;
      case 'tt':
      case 'tromp-taylor':
        return trompTaylor;
      default:
        return japanese;
    }
  }
}

class Move {
  final int pla;
  final int loc; // Board.passLoc for a pass
  const Move(this.pla, this.loc);
  bool get isPass => loc == Board.passLoc;
}

/// Board plus the history the featurizer needs (previous boards, previous moves).
class GoPosition {
  final int boardSize;
  Rules rules;
  Board board;
  final List<Board> boards = [];
  final List<Move> moves = [];

  GoPosition(this.boardSize, this.rules) : board = Board(boardSize, boardSize) {
    boards.add(board.copy());
  }

  int get nextPlayer => board.pla;

  bool isLegal(int pla, int loc) => board.wouldBeLegal(pla, loc);

  void play(int pla, int loc) {
    board.play(pla, loc);
    moves.add(Move(pla, loc));
    boards.add(board.copy());
  }

  void undo() {
    if (moves.isEmpty) return;
    moves.removeLast();
    boards.removeLast();
    board = boards.last.copy();
  }

  GoPosition copy() {
    final p = GoPosition(boardSize, rules);
    p.board = board.copy();
    p.boards
      ..clear()
      ..addAll(boards.map((b) => b.copy()));
    p.moves
      ..clear()
      ..addAll(moves);
    return p;
  }
}

class FeatureResult {
  final Float32List bin;
  final Float32List global;
  FeatureResult(this.bin, this.global);
}

class Features {
  final int posLen;
  const Features(this.posLen);

  int xyToTensorPos(int x, int y) => y * posLen + x;
  int locToTensorPos(int loc, Board b) => b.locY(loc) * posLen + b.locX(loc);

  /// Calls [f] for each stone belonging to a ladder-captured group.
  void iterLadders(Board b, void Function(int loc, int pos, List<int> workingMoves) f) {
    final chainHeadsSolved = <int, bool>{};
    final copy = b.copy();

    for (var y = 0; y < b.ySize; y++) {
      for (var x = 0; x < b.xSize; x++) {
        final pos = xyToTensorPos(x, y);
        final loc = b.loc(x, y);
        final stone = b.board[loc];

        if (stone == Board.black || stone == Board.white) {
          final libs = b.numLiberties(loc);
          if (libs == 1 || libs == 2) {
            final head = b.groupHead[loc];
            if (chainHeadsSolved.containsKey(head)) {
              if (chainHeadsSolved[head]!) f(loc, pos, const []);
            } else {
              // Search on the copy so we don't disturb tracking of solved heads.
              List<int> workingMoves;
              bool laddered;
              if (libs == 1) {
                workingMoves = const [];
                laddered = copy.searchIsLadderCaptured(loc, true);
              } else {
                workingMoves = copy.searchIsLadderCapturedAttackerFirst2Libs(loc);
                laddered = workingMoves.isNotEmpty;
              }
              chainHeadsSolved[head] = laddered;
              if (laddered) f(loc, pos, workingMoves);
            }
          }
        }
      }
    }
  }

  FeatureResult fillRowFeatures(GoPosition pos) {
    final b = pos.board;
    final rules = pos.rules;
    final pla = b.pla;
    final opp = Board.getOpp(pla);
    final moves = pos.moves;
    final boards = pos.boards;
    final moveIdx = moves.length;

    final bin = Float32List(kNumBinFeatures * posLen * posLen);
    final global = Float32List(kNumGlobalFeatures);
    final area = posLen * posLen;
    void setBin(int channel, int p, double v) => bin[channel * area + p] = v;

    final xSize = b.xSize;
    final ySize = b.ySize;

    for (var y = 0; y < ySize; y++) {
      for (var x = 0; x < xSize; x++) {
        final p = xyToTensorPos(x, y);
        setBin(0, p, 1.0);
        final loc = b.loc(x, y);
        final stone = b.board[loc];
        if (stone == pla) {
          setBin(1, p, 1.0);
        } else if (stone == opp) {
          setBin(2, p, 1.0);
        }
        if (stone == pla || stone == opp) {
          final libs = b.numLiberties(loc);
          if (libs == 1) {
            setBin(3, p, 1.0);
          } else if (libs == 2) {
            setBin(4, p, 1.0);
          } else if (libs == 3) {
            setBin(5, p, 1.0);
          }
        }
      }
    }

    // No superko handling, matching the Python reference. Channels 7/8 (encore ko
    // prohibition) stay blank for the same reason.
    if (b.simpleKoPoint != null) {
      setBin(6, locToTensorPos(b.simpleKoPoint!, b), 1.0);
    }

    // Move history: channels 9-13, with passes recorded in globals 0-4 instead.
    if (moveIdx >= 1 && moves[moveIdx - 1].pla == opp) {
      final prev1 = moves[moveIdx - 1].loc;
      if (prev1 != Board.passLoc) {
        setBin(9, locToTensorPos(prev1, b), 1.0);
      } else {
        global[0] = 1.0;
      }

      if (moveIdx >= 2 && moves[moveIdx - 2].pla == pla) {
        final prev2 = moves[moveIdx - 2].loc;
        if (prev2 != Board.passLoc) {
          setBin(10, locToTensorPos(prev2, b), 1.0);
        } else {
          global[1] = 1.0;
        }

        if (moveIdx >= 3 && moves[moveIdx - 3].pla == opp) {
          final prev3 = moves[moveIdx - 3].loc;
          if (prev3 != Board.passLoc) {
            setBin(11, locToTensorPos(prev3, b), 1.0);
          } else {
            global[2] = 1.0;
          }

          if (moveIdx >= 4 && moves[moveIdx - 4].pla == pla) {
            final prev4 = moves[moveIdx - 4].loc;
            if (prev4 != Board.passLoc) {
              setBin(12, locToTensorPos(prev4, b), 1.0);
            } else {
              global[3] = 1.0;
            }

            if (moveIdx >= 5 && moves[moveIdx - 5].pla == opp) {
              final prev5 = moves[moveIdx - 5].loc;
              if (prev5 != Board.passLoc) {
                setBin(13, locToTensorPos(prev5, b), 1.0);
              } else {
                global[4] = 1.0;
              }
            }
          }
        }
      }
    }

    // Ladders: current (14, plus escape moves in 17), previous (15), one before that (16).
    iterLadders(b, (loc, p, workingMoves) {
      setBin(14, p, 1.0);
      if (b.board[loc] == opp && b.numLiberties(loc) > 1) {
        for (final wm in workingMoves) {
          setBin(17, locToTensorPos(wm, b), 1.0);
        }
      }
    });

    final prevBoard = moveIdx > 0 ? boards[moveIdx - 1] : b;
    iterLadders(prevBoard, (loc, p, _) => setBin(15, p, 1.0));

    final prevPrevBoard = moveIdx > 1 ? boards[moveIdx - 2] : prevBoard;
    iterLadders(prevPrevBoard, (loc, p, _) => setBin(16, p, 1.0));

    // Channels 18/19 (area) are only populated for area scoring or the second encore.
    // SHAPE plays territory scoring with encorePhase 0, where KataGo's own featurizer
    // leaves them blank -- so pass-alive is never needed. Anything else would require
    // porting calculateArea/calculateNonDameTouchingArea, so refuse rather than
    // silently emit zeros and produce a subtly wrong policy.
    final needsArea = rules.scoringRule == 'SCORING_AREA' || rules.encorePhase >= 2;
    if (needsArea) {
      throw UnimplementedError(
        'Area scoring (${rules.scoringRule}, encorePhase ${rules.encorePhase}) needs '
        'calculateArea/pass-alive, which is not ported yet. Use territory scoring.',
      );
    }

    final bArea = xSize * ySize;
    final whiteKomi = rules.whiteKomi;
    double selfKomi;
    if (rules.scoringRule == 'SCORING_TERRITORY') {
      final whiteSelfKomi =
          whiteKomi + b.numNonPassMovesMade(Board.black) - b.numNonPassMovesMade(Board.white);
      selfKomi = pla == Board.white ? whiteSelfKomi : -whiteSelfKomi;
    } else {
      selfKomi = pla == Board.white ? whiteKomi : -whiteKomi;
    }
    if (selfKomi > bArea + 1) selfKomi = (bArea + 1).toDouble();
    if (selfKomi < -bArea - 1) selfKomi = (-bArea - 1).toDouble();
    global[5] = selfKomi / 20.0;

    switch (rules.koRule) {
      case 'KO_SIMPLE':
        break;
      case 'KO_POSITIONAL':
      case 'KO_SPIGHT':
        global[6] = 1.0;
        global[7] = 0.5;
        break;
      case 'KO_SITUATIONAL':
        global[6] = 1.0;
        global[7] = -0.5;
        break;
      default:
        throw ArgumentError('unknown koRule ${rules.koRule}');
    }

    if (rules.multiStoneSuicideLegal) global[8] = 1.0;

    if (rules.scoringRule == 'SCORING_TERRITORY') global[9] = 1.0;

    if (rules.taxRule == 'TAX_SEKI') {
      global[10] = 1.0;
    } else if (rules.taxRule == 'TAX_ALL') {
      global[10] = 1.0;
      global[11] = 1.0;
    }

    if (rules.encorePhase > 0) global[12] = 1.0;
    if (rules.encorePhase > 1) global[13] = 1.0;
    global[14] = rules.passWouldEndPhase ? 1.0 : 0.0;

    global[15] = rules.asymPowersOfTwo != 0 ? 1.0 : 0.0;
    global[16] = rules.asymPowersOfTwo;

    if (rules.hasButton && !moves.any((m) => m.isPass)) global[17] = 1.0;

    if (rules.scoringRule == 'SCORING_AREA' || rules.encorePhase > 1) {
      final boardAreaIsEven = xSize % 2 == 0 || ySize % 2 == 0;
      final drawableKomisAreEven = boardAreaIsEven;
      final komiFloor = drawableKomisAreEven
          ? (selfKomi / 2.0).floorToDouble() * 2.0
          : ((selfKomi - 1.0) / 2.0).floorToDouble() * 2.0 + 1.0;

      var delta = selfKomi - komiFloor;
      if (delta < 0.0) delta = 0.0;
      if (delta > 2.0) delta = 2.0;

      final double wave;
      if (delta < 0.5) {
        wave = delta;
      } else if (delta < 1.5) {
        wave = 1.0 - delta;
      } else {
        wave = delta - 2.0;
      }
      global[18] = wave;
    }

    return FeatureResult(bin, global);
  }
}

/// Column letters used by GTP, skipping I.
const String gtpCols = 'ABCDEFGHJKLMNOPQRST';

String locToGtp(int loc, Board b) {
  if (loc == Board.passLoc) return 'pass';
  return '${gtpCols[b.locX(loc)]}${b.ySize - b.locY(loc)}';
}

int gtpToLoc(String gtp, Board b) {
  if (gtp.toLowerCase() == 'pass') return Board.passLoc;
  final x = gtpCols.indexOf(gtp[0].toUpperCase());
  final y = b.ySize - int.parse(gtp.substring(1));
  return b.loc(x, y);
}
