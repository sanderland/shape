// Faithful port of KataGo's katago/game/board.py.
//
// Deliberately transliterated rather than reimplemented: the ladder search below
// depends on the exact incremental bookkeeping (group_head / group_liberty_count /
// group_next + playRecordedUnsafe/undo), so "cleaner" flood-fill equivalents would
// change its behaviour in subtle ways. Correctness is pinned by
// test/featurizer_test.dart against fixtures generated from the Python original.
//
// Omitted on purpose: zobrist hashing (features never read it, and the Python
// table is seeded from Python's RNG so it cannot be reproduced anyway) and the
// area/pass-alive code (see features.dart -- unused for territory scoring).

import 'dart:typed_data';

class IllegalMoveError implements Exception {
  final String message;
  IllegalMoveError(this.message);
  @override
  String toString() => 'IllegalMoveError: $message';
}

/// Record needed to undo a played move during ladder search.
class MoveRecord {
  final int pla;
  final int loc;
  final int? simpleKoPoint;
  final List<int> capDirs;
  final bool selfCap;
  final int capturesBlack;
  final int capturesWhite;
  final int movesBlack;
  final int movesWhite;

  MoveRecord(this.pla, this.loc, this.simpleKoPoint, this.capDirs, this.selfCap,
      this.capturesBlack, this.capturesWhite, this.movesBlack, this.movesWhite);
}

class Board {
  static const int empty = 0;
  static const int black = 1;
  static const int white = 2;
  static const int wall = 3;
  static const int passLoc = 0;

  static int getOpp(int pla) => 3 - pla;

  final int xSize;
  final int ySize;
  late final int arrSize;
  late final int dy;
  late final List<int> adj;
  late final List<int> diag;

  int pla = black;
  late Int8List board;
  late Int32List groupHead;
  late Int32List groupStoneCount;
  late Int32List groupLibertyCount;
  late Int32List groupNext;
  late Int32List groupPrev;
  int? simpleKoPoint;
  int capturesBlack = 0;
  int capturesWhite = 0;
  int movesBlack = 0;
  int movesWhite = 0;

  Board(this.xSize, this.ySize) {
    if (xSize < 2 || xSize > 50 || ySize < 2 || ySize > 50) {
      throw ArgumentError('Invalid board size: ${xSize}x$ySize');
    }
    arrSize = (xSize + 1) * (ySize + 2) + 1;
    dy = xSize + 1;
    adj = [-dy, -1, 1, dy];
    diag = [-dy - 1, -dy + 1, dy - 1, dy + 1];

    board = Int8List(arrSize);
    groupHead = Int32List(arrSize);
    groupStoneCount = Int32List(arrSize);
    groupLibertyCount = Int32List(arrSize);
    groupNext = Int32List(arrSize);
    groupPrev = Int32List(arrSize);

    for (var i = -1; i <= xSize; i++) {
      board[loc(i, -1)] = wall;
      board[loc(i, ySize)] = wall;
    }
    for (var i = -1; i <= ySize; i++) {
      board[loc(-1, i)] = wall;
      board[loc(xSize, i)] = wall;
    }
    groupHead[0] = -1;
    groupNext[0] = -1;
    groupPrev[0] = -1;
  }

  Board copy() {
    final b = Board(xSize, ySize);
    b.pla = pla;
    b.board.setAll(0, board);
    b.groupHead.setAll(0, groupHead);
    b.groupStoneCount.setAll(0, groupStoneCount);
    b.groupLibertyCount.setAll(0, groupLibertyCount);
    b.groupNext.setAll(0, groupNext);
    b.groupPrev.setAll(0, groupPrev);
    b.simpleKoPoint = simpleKoPoint;
    b.capturesBlack = capturesBlack;
    b.capturesWhite = capturesWhite;
    b.movesBlack = movesBlack;
    b.movesWhite = movesWhite;
    return b;
  }

  int loc(int x, int y) => (x + 1) + dy * (y + 1);
  int locX(int l) => (l % dy) - 1;
  int locY(int l) => (l ~/ dy) - 1;

  bool isOnBoard(int l) => l >= 0 && l < arrSize && board[l] != wall;

  bool isAdjacent(int loc1, int loc2) =>
      loc1 == loc2 + adj[0] || loc1 == loc2 + adj[1] || loc1 == loc2 + adj[2] || loc1 == loc2 + adj[3];

  int numLiberties(int l) {
    if (board[l] == empty || board[l] == wall) return 0;
    return groupLibertyCount[groupHead[l]];
  }

  int numNonPassMovesMade(int p) => p == black ? movesBlack : movesWhite;

  bool wouldBeLegal(int p, int l) {
    if (p != black && p != white) return false;
    if (l == passLoc) return true;
    if (!isOnBoard(l)) return false;
    if (board[l] != empty) return false;
    if (wouldBeSingleStoneSuicide(p, l)) return false;
    if (l == simpleKoPoint) return false;
    return true;
  }

  bool wouldBeSingleStoneSuicide(int p, int l) {
    final opp = getOpp(p);
    for (var i = 0; i < 4; i++) {
      final a = l + adj[i];
      if (board[a] == empty || (board[a] == opp && groupLibertyCount[groupHead[a]] == 1)) return false;
    }
    for (var i = 0; i < 4; i++) {
      if (board[l + adj[i]] == p) return false;
    }
    return true;
  }

  /// Liberties a new stone here would have, capped at [maxLibs].
  int getLibertiesAfterPlay(int p, int l, int maxLibs) {
    final opp = getOpp(p);
    final libs = <int>[];
    final capturedGroupHeads = <int>[];

    for (var i = 0; i < 4; i++) {
      final a = l + adj[i];
      if (board[a] == empty) {
        libs.add(a);
        if (libs.length >= maxLibs) return maxLibs;
      } else if (board[a] == opp && numLiberties(a) == 1) {
        libs.add(a);
        if (libs.length >= maxLibs) return maxLibs;
        final head = groupHead[a];
        if (!capturedGroupHeads.contains(head)) capturedGroupHeads.add(head);
      }
    }

    bool wouldBeEmpty(int possibleLib) {
      if (board[possibleLib] == empty) return true;
      if (board[possibleLib] == opp) return capturedGroupHeads.contains(groupHead[possibleLib]);
      return false;
    }

    final connecting = <int>[];
    for (var i = 0; i < 4; i++) {
      final a = l + adj[i];
      if (board[a] == p) {
        final head = groupHead[a];
        if (!connecting.contains(head)) {
          connecting.add(head);
          var cur = a;
          while (true) {
            for (var k = 0; k < 4; k++) {
              final possibleLib = cur + adj[k];
              if (possibleLib != l && wouldBeEmpty(possibleLib) && !libs.contains(possibleLib)) {
                libs.add(possibleLib);
                if (libs.length >= maxLibs) return maxLibs;
              }
            }
            cur = groupNext[cur];
            if (cur == a) break;
          }
        }
      }
    }
    return libs.length;
  }

  void play(int p, int l) {
    if (p != black && p != white) throw IllegalMoveError('Invalid pla for board.play');
    if (l != passLoc) {
      if (!isOnBoard(l)) throw IllegalMoveError('Invalid loc for board.play');
      if (board[l] != empty) throw IllegalMoveError('Location is nonempty');
      if (wouldBeSingleStoneSuicide(p, l)) throw IllegalMoveError('Illegal single stone suicide');
      if (l == simpleKoPoint) throw IllegalMoveError('Illegal simple ko recapture');
    }
    playUnsafe(p, l);
  }

  void playUnsafe(int p, int l) {
    if (l == passLoc) {
      simpleKoPoint = null;
      pla = getOpp(p);
    } else {
      addUnsafe(p, l);
      pla = getOpp(p);
    }
  }

  MoveRecord playRecordedUnsafe(int p, int l) {
    final capDirs = <int>[];
    final opp = getOpp(p);
    final oldKo = simpleKoPoint;
    for (var i = 0; i < 4; i++) {
      final a = l + adj[i];
      if (board[a] == opp && groupLibertyCount[groupHead[a]] == 1) capDirs.add(i);
    }
    final oldCapB = capturesBlack, oldCapW = capturesWhite;
    final oldMovB = movesBlack, oldMovW = movesWhite;
    playUnsafe(p, l);
    final selfCap = board[l] == empty;
    return MoveRecord(p, l, oldKo, capDirs, selfCap, oldCapB, oldCapW, oldMovB, oldMovW);
  }

  void undo(MoveRecord record) {
    final p = record.pla;
    final l = record.loc;
    final opp = getOpp(p);

    simpleKoPoint = record.simpleKoPoint;
    pla = p;
    capturesBlack = record.capturesBlack;
    capturesWhite = record.capturesWhite;
    movesBlack = record.movesBlack;
    movesWhite = record.movesWhite;

    if (l == passLoc) return;

    for (final capdir in record.capDirs) {
      final a = l + adj[capdir];
      if (board[a] == empty) floodFillStones(opp, a);
    }
    if (record.selfCap) floodFillStones(p, l);

    board[l] = empty;

    final head = groupHead[l];
    final stoneCount = groupStoneCount[head];
    groupStoneCount[head] = 0;
    groupLibertyCount[head] = 0;

    changeSurroundingLiberties(l, getOpp(p), 1);

    if (stoneCount > 1) {
      var cur = l;
      while (true) {
        groupHead[cur] = passLoc;
        cur = groupNext[cur];
        if (cur == l) break;
      }
      for (var i = 0; i < 4; i++) {
        final a = l + adj[i];
        if (board[a] == p && groupHead[a] == passLoc) rebuildChain(p, a);
      }
    }

    groupHead[l] = 0;
    groupNext[l] = 0;
    groupPrev[l] = 0;
  }

  void floodFillStones(int p, int l) {
    final head = l;
    groupLibertyCount[head] = 0;
    groupStoneCount[head] = 0;
    final front = _floodFillStonesHelper(head, head, head, p);
    groupNext[head] = front;
    groupPrev[front] = head;
  }

  int _floodFillStonesHelper(int head, int tailTarget, int l, int p) {
    board[l] = p;
    groupHead[l] = head;
    groupStoneCount[head] += 1;
    groupNext[l] = tailTarget;
    groupPrev[tailTarget] = l;
    changeSurroundingLiberties(l, getOpp(p), -1);
    var nextTailTarget = l;
    for (var i = 0; i < 4; i++) {
      final a = l + adj[i];
      if (board[a] == empty) nextTailTarget = _floodFillStonesHelper(head, nextTailTarget, a, p);
    }
    return nextTailTarget;
  }

  void rebuildChain(int p, int l) {
    final head = l;
    groupLibertyCount[head] = 0;
    groupStoneCount[head] = 0;
    final front = _rebuildChainHelper(head, head, head, p);
    groupNext[head] = front;
    groupPrev[front] = head;
  }

  int _rebuildChainHelper(int head, int tailTarget, int l, int p) {
    for (final dloc in adj) {
      if (board[l + dloc] == empty && !isGroupAdjacent(head, l + dloc)) {
        groupLibertyCount[head] += 1;
      }
    }
    groupHead[l] = head;
    groupStoneCount[head] += 1;
    groupNext[l] = tailTarget;
    groupPrev[tailTarget] = l;
    var nextTailTarget = l;
    for (var i = 0; i < 4; i++) {
      final a = l + adj[i];
      if (board[a] == p && groupHead[a] != head) {
        nextTailTarget = _rebuildChainHelper(head, nextTailTarget, a, p);
      }
    }
    return nextTailTarget;
  }

  void addUnsafe(int p, int l) {
    final opp = getOpp(p);

    board[l] = p;
    groupHead[l] = l;
    groupStoneCount[l] = 1;
    var liberties = 0;
    for (final dloc in adj) {
      if (board[l + dloc] == empty) liberties += 1;
    }
    groupLibertyCount[l] = liberties;
    groupNext[l] = l;
    groupPrev[l] = l;

    final adj0 = l + adj[0], adj1 = l + adj[1], adj2 = l + adj[2], adj3 = l + adj[3];

    // Fill surrounding liberties, carefully avoiding double-counting.
    if (board[adj0] == black || board[adj0] == white) {
      groupLibertyCount[groupHead[adj0]] -= 1;
    }
    if (board[adj1] == black || board[adj1] == white) {
      if (groupHead[adj1] != groupHead[adj0]) groupLibertyCount[groupHead[adj1]] -= 1;
    }
    if (board[adj2] == black || board[adj2] == white) {
      if (groupHead[adj2] != groupHead[adj0] && groupHead[adj2] != groupHead[adj1]) {
        groupLibertyCount[groupHead[adj2]] -= 1;
      }
    }
    if (board[adj3] == black || board[adj3] == white) {
      if (groupHead[adj3] != groupHead[adj0] &&
          groupHead[adj3] != groupHead[adj1] &&
          groupHead[adj3] != groupHead[adj2]) {
        groupLibertyCount[groupHead[adj3]] -= 1;
      }
    }

    if (board[adj0] == p) mergeUnsafe(l, adj0);
    if (board[adj1] == p) mergeUnsafe(l, adj1);
    if (board[adj2] == p) mergeUnsafe(l, adj2);
    if (board[adj3] == p) mergeUnsafe(l, adj3);

    var oppStonesCaptured = 0;
    var caploc = 0;
    if (board[adj0] == opp && groupLibertyCount[groupHead[adj0]] == 0) {
      oppStonesCaptured += groupStoneCount[groupHead[adj0]];
      caploc = adj0;
      removeUnsafe(adj0);
    }
    if (board[adj1] == opp && groupLibertyCount[groupHead[adj1]] == 0) {
      oppStonesCaptured += groupStoneCount[groupHead[adj1]];
      caploc = adj1;
      removeUnsafe(adj1);
    }
    if (board[adj2] == opp && groupLibertyCount[groupHead[adj2]] == 0) {
      oppStonesCaptured += groupStoneCount[groupHead[adj2]];
      caploc = adj2;
      removeUnsafe(adj2);
    }
    if (board[adj3] == opp && groupLibertyCount[groupHead[adj3]] == 0) {
      oppStonesCaptured += groupStoneCount[groupHead[adj3]];
      caploc = adj3;
      removeUnsafe(adj3);
    }

    var plaStonesCaptured = 0;
    if (groupLibertyCount[groupHead[l]] == 0) {
      plaStonesCaptured += groupStoneCount[groupHead[l]];
      removeUnsafe(l);
    }

    if (p == black) {
      capturesBlack += plaStonesCaptured;
      capturesWhite += oppStonesCaptured;
      movesBlack += 1;
    } else {
      capturesWhite += plaStonesCaptured;
      capturesBlack += oppStonesCaptured;
      movesWhite += 1;
    }

    if (oppStonesCaptured == 1 &&
        groupStoneCount[groupHead[l]] == 1 &&
        groupLibertyCount[groupHead[l]] == 1) {
      simpleKoPoint = caploc;
    } else {
      simpleKoPoint = null;
    }
  }

  void changeSurroundingLiberties(int l, int p, int delta) {
    final adj0 = l + adj[0], adj1 = l + adj[1], adj2 = l + adj[2], adj3 = l + adj[3];
    if (board[adj0] == p) groupLibertyCount[groupHead[adj0]] += delta;
    if (board[adj1] == p) {
      if (groupHead[adj1] != groupHead[adj0]) groupLibertyCount[groupHead[adj1]] += delta;
    }
    if (board[adj2] == p) {
      if (groupHead[adj2] != groupHead[adj0] && groupHead[adj2] != groupHead[adj1]) {
        groupLibertyCount[groupHead[adj2]] += delta;
      }
    }
    if (board[adj3] == p) {
      if (groupHead[adj3] != groupHead[adj0] &&
          groupHead[adj3] != groupHead[adj1] &&
          groupHead[adj3] != groupHead[adj2]) {
        groupLibertyCount[groupHead[adj3]] += delta;
      }
    }
  }

  int countImmediateLiberties(int l) {
    var count = 0;
    for (var i = 0; i < 4; i++) {
      if (board[l + adj[i]] == empty) count += 1;
    }
    return count;
  }

  bool isGroupAdjacent(int head, int l) =>
      groupHead[l + adj[0]] == head ||
      groupHead[l + adj[1]] == head ||
      groupHead[l + adj[2]] == head ||
      groupHead[l + adj[3]] == head;

  void mergeUnsafe(int loc0, int loc1) {
    int parent, child;
    if (groupStoneCount[groupHead[loc0]] >= groupStoneCount[groupHead[loc1]]) {
      parent = loc0;
      child = loc1;
    } else {
      child = loc0;
      parent = loc1;
    }

    final phead = groupHead[parent];
    final chead = groupHead[child];
    if (phead == chead) return;

    final newStoneCount = groupStoneCount[phead] + groupStoneCount[chead];
    var newLiberties = groupLibertyCount[phead];
    var l = child;
    while (true) {
      for (var i = 0; i < 4; i++) {
        final a = l + adj[i];
        if (board[a] == empty && !isGroupAdjacent(phead, a)) newLiberties += 1;
      }
      groupHead[l] = phead;
      l = groupNext[l];
      if (l == child) break;
    }

    groupStoneCount[chead] = 0;
    groupLibertyCount[chead] = 0;
    groupStoneCount[phead] = newStoneCount;
    groupLibertyCount[phead] = newLiberties;

    final plast = groupPrev[phead];
    final clast = groupPrev[chead];
    groupNext[clast] = phead;
    groupNext[plast] = chead;
    groupPrev[chead] = plast;
    groupPrev[phead] = clast;
  }

  void removeUnsafe(int group) {
    final head = groupHead[group];
    final p = board[group];
    final opp = getOpp(p);

    var l = group;
    while (true) {
      final adj0 = l + adj[0], adj1 = l + adj[1], adj2 = l + adj[2], adj3 = l + adj[3];
      if (board[adj0] == opp) groupLibertyCount[groupHead[adj0]] += 1;
      if (board[adj1] == opp) {
        if (groupHead[adj1] != groupHead[adj0]) groupLibertyCount[groupHead[adj1]] += 1;
      }
      if (board[adj2] == opp) {
        if (groupHead[adj2] != groupHead[adj0] && groupHead[adj2] != groupHead[adj1]) {
          groupLibertyCount[groupHead[adj2]] += 1;
        }
      }
      if (board[adj3] == opp) {
        if (groupHead[adj3] != groupHead[adj0] &&
            groupHead[adj3] != groupHead[adj1] &&
            groupHead[adj3] != groupHead[adj2]) {
          groupLibertyCount[groupHead[adj3]] += 1;
        }
      }

      final nextLoc = groupNext[l];
      board[l] = empty;
      groupHead[l] = 0;
      groupNext[l] = 0;
      groupPrev[l] = 0;
      l = nextLoc;
      if (l == group) break;
    }

    groupStoneCount[head] = 0;
    groupLibertyCount[head] = 0;
  }

  // ---- ladder search ----

  void findLiberties(int l, List<int> buf) {
    var cur = l;
    while (true) {
      for (var i = 0; i < 4; i++) {
        final lib = cur + adj[i];
        if (board[lib] == empty) {
          if (!buf.contains(lib)) buf.add(lib);
        }
      }
      cur = groupNext[cur];
      if (cur == l) break;
    }
  }

  void findLibertyGainingCaptures(int l, List<int> buf) {
    final p = board[l];
    final opp = getOpp(p);
    final chainHeadsChecked = <int>[];
    var cur = l;
    while (true) {
      for (var i = 0; i < 4; i++) {
        final a = cur + adj[i];
        if (board[a] == opp) {
          final head = groupHead[a];
          if (groupLibertyCount[head] == 1) {
            if (!chainHeadsChecked.contains(head)) {
              findLiberties(a, buf);
              chainHeadsChecked.add(head);
            }
          }
        }
      }
      cur = groupNext[cur];
      if (cur == l) break;
    }
  }

  bool hasLibertyGainingCaptures(int l) {
    final p = board[l];
    final opp = getOpp(p);
    var cur = l;
    while (true) {
      for (var i = 0; i < 4; i++) {
        final a = cur + adj[i];
        if (board[a] == opp && groupLibertyCount[groupHead[a]] == 1) return true;
      }
      cur = groupNext[cur];
      if (cur == l) break;
    }
    return false;
  }

  bool wouldBeKoCapture(int l, int p) {
    if (board[l] != empty) return false;
    final opp = getOpp(p);
    int? oppCapturableLoc;
    for (var i = 0; i < 4; i++) {
      final a = l + adj[i];
      if (board[a] != wall && board[a] != opp) return false;
      if (board[a] == opp && groupLibertyCount[groupHead[a]] == 1) {
        if (oppCapturableLoc != null) return false;
        oppCapturableLoc = a;
      }
    }
    if (oppCapturableLoc == null) return false;
    return groupStoneCount[groupHead[oppCapturableLoc]] == 1;
  }

  double countHeuristicConnectionLiberties(int l, int p) {
    var count = 0.0;
    for (var i = 0; i < 4; i++) {
      final a = l + adj[i];
      if (board[a] == p) {
        final v = groupLibertyCount[groupHead[a]] - 1.5;
        count += v > 0.0 ? v : 0.0;
      }
    }
    return count;
  }

  List<int> searchIsLadderCapturedAttackerFirst2Libs(int l) {
    if (!isOnBoard(l)) return const [];
    if (board[l] != black && board[l] != white) return const [];
    if (groupLibertyCount[groupHead[l]] != 2) return const [];

    final p = board[l];
    final opp = getOpp(p);

    final moves = <int>[];
    findLiberties(l, moves);
    assert(moves.length == 2);

    final move0 = moves[0];
    final move1 = moves[1];
    var move0Works = false;
    var move1Works = false;

    if (wouldBeLegal(opp, move0)) {
      final record = playRecordedUnsafe(opp, move0);
      move0Works = searchIsLadderCaptured(l, true);
      undo(record);
    }
    if (wouldBeLegal(opp, move1)) {
      final record = playRecordedUnsafe(opp, move1);
      move1Works = searchIsLadderCaptured(l, true);
      undo(record);
    }

    final workingMoves = <int>[];
    if (move0Works) workingMoves.add(move0);
    if (move1Works) workingMoves.add(move1);
    return workingMoves;
  }

  bool searchIsLadderCaptured(int l, bool defenderFirst) {
    if (!isOnBoard(l)) return false;
    if (board[l] != black && board[l] != white) return false;
    if (groupLibertyCount[groupHead[l]] > 2 ||
        (defenderFirst && groupLibertyCount[groupHead[l]] > 1)) {
      return false;
    }

    final p = board[l];
    final opp = getOpp(p);

    // A bit bigger than the board, out of paranoia about recaptures lengthening the sequence.
    final arrSizeLocal = xSize * ySize * 2;

    final moveLists = List<List<int>>.generate(arrSizeLocal, (_) => <int>[]);
    final moveListCur = List<int>.filled(arrSizeLocal, 0);
    final records = List<MoveRecord?>.filled(arrSizeLocal, null);
    var stackIdx = 0;

    moveLists[0] = <int>[];
    moveListCur[0] = -1;

    var returnValue = false;
    var returnedFromDeeper = false;

    // Clear the ko loc for the defender at the root - assume all kos work for the defender.
    final savedKo = simpleKoPoint;
    if (defenderFirst) simpleKoPoint = null;

    while (true) {
      if (stackIdx <= -1) {
        simpleKoPoint = savedKo;
        return returnValue;
      }

      final isDefender =
          (defenderFirst && stackIdx % 2 == 0) || (!defenderFirst && stackIdx % 2 == 1);

      if (moveListCur[stackIdx] == -1) {
        final libs = groupLibertyCount[groupHead[l]];

        if (!isDefender && libs <= 1) {
          returnValue = true;
          returnedFromDeeper = true;
          stackIdx -= 1;
          continue;
        }
        if (!isDefender && libs >= 3) {
          returnValue = false;
          returnedFromDeeper = true;
          stackIdx -= 1;
          continue;
        }
        if (isDefender && libs >= 2) {
          returnValue = false;
          returnedFromDeeper = true;
          stackIdx -= 1;
          continue;
        }
        // Don't claim ladders that depend on kos; also guards against infinite loops.
        if (isDefender && simpleKoPoint != null) {
          returnValue = false;
          returnedFromDeeper = true;
          stackIdx -= 1;
          continue;
        }

        if (isDefender) {
          moveLists[stackIdx] = <int>[];
          findLibertyGainingCaptures(l, moveLists[stackIdx]);
          findLiberties(l, moveLists[stackIdx]);
        } else {
          moveLists[stackIdx] = <int>[];
          findLiberties(l, moveLists[stackIdx]);
          assert(moveLists[stackIdx].length == 2);

          final move0 = moveLists[stackIdx][0];
          final move1 = moveLists[stackIdx][1];

          var libs0 = countImmediateLiberties(move0).toDouble();
          var libs1 = countImmediateLiberties(move1).toDouble();

          // Double-ko death: assume the attacker wins.
          if (libs0 == 0 && libs1 == 0 && wouldBeKoCapture(move0, opp) && wouldBeKoCapture(move1, opp)) {
            if (getLibertiesAfterPlay(p, move0, 3) <= 2 && getLibertiesAfterPlay(p, move1, 3) <= 2) {
              if (hasLibertyGainingCaptures(l)) {
                returnValue = true;
                returnedFromDeeper = true;
                stackIdx -= 1;
                continue;
              }
            }
          }

          if (!isAdjacent(move0, move1)) {
            if (libs0 >= 3 && libs1 >= 3) {
              returnValue = false;
              returnedFromDeeper = true;
              stackIdx -= 1;
              continue;
            } else if (libs0 >= 3) {
              moveLists[stackIdx] = [move0];
            } else if (libs1 >= 3) {
              moveLists[stackIdx] = [move1];
            }
          }

          if (moveLists[stackIdx].length > 1) {
            libs0 += countHeuristicConnectionLiberties(move0, p);
            libs1 += countHeuristicConnectionLiberties(move1, p);
            if (libs1 > libs0) {
              moveLists[stackIdx][0] = move1;
              moveLists[stackIdx][1] = move0;
            }
          }
        }

        moveListCur[stackIdx] = 0;
      } else {
        if (returnedFromDeeper) undo(records[stackIdx]!);

        if (isDefender && !returnValue) {
          returnedFromDeeper = true;
          stackIdx -= 1;
          continue;
        }
        if (!isDefender && returnValue) {
          returnedFromDeeper = true;
          stackIdx -= 1;
          continue;
        }
        moveListCur[stackIdx] += 1;
      }

      if (moveListCur[stackIdx] >= moveLists[stackIdx].length) {
        returnValue = isDefender;
        returnedFromDeeper = true;
        stackIdx -= 1;
        continue;
      }

      final move = moveLists[stackIdx][moveListCur[stackIdx]];
      final mover = isDefender ? p : opp;

      // Illegal move: treat as a failed move but stay at this level and try the next.
      if (!wouldBeLegal(mover, move)) {
        returnValue = isDefender;
        returnedFromDeeper = false;
        continue;
      }

      records[stackIdx] = playRecordedUnsafe(mover, move);

      stackIdx += 1;
      moveListCur[stackIdx] = -1;
      moveLists[stackIdx] = <int>[];
    }
  }
}
