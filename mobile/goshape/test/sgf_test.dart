import 'package:flutter_test/flutter_test.dart';
import 'package:goshape/engine/board.dart';
import 'package:goshape/game/sgf.dart';
import 'package:goshape/game/shape_game.dart';

void main() {
  test('parser keeps sequences, variations, and escaped values', () {
    final root = parseSgf(
      r'(;GM[1]C[closing \] bracket];B[cc];W[](;B[dd])(;B[ee]))',
    );

    expect(root.value('C'), 'closing ] bracket');
    final black = root.children.single;
    final whitePass = black.children.single;
    expect(black.value('B'), 'cc');
    expect(whitePass.value('W'), '');
    expect(whitePass.children.map((n) => n.value('B')), ['dd', 'ee']);
  });

  test(
    'loading an SGF restores its board, komi, passes, and variations',
    () async {
      final game = ShapeGame(null, boardSize: 19);
      await game.start();

      await game.loadSgf(
        '(;GM[1]FF[4]SZ[9]KM[5.5]RU[Japanese];B[cc];W[](;B[dd])(;B[ee]))',
      );

      expect(game.boardSize, 9);
      expect(game.rules.whiteKomi, 5.5);
      expect(game.cursor, 3);
      expect(game.line[1].isPass, isTrue);
      final branch = game.root.children.single.children.single;
      expect(branch.children.length, 2);
      expect(game.pos.board.board[game.pos.board.loc(2, 2)], Board.black);
      expect(game.pos.board.board[game.pos.board.loc(3, 3)], Board.black);
    },
  );

  test('saved trees round-trip with the selected variation first', () async {
    final original = ShapeGame(null, boardSize: 9);
    await original.start();
    await original.playAt(2, 2);
    await original.goFirst();
    await original.playAt(8, 8);

    final loaded = ShapeGame(null, boardSize: 19);
    await loaded.start();
    await loaded.loadSgf(original.toSgf());

    expect(loaded.boardSize, 9);
    expect(loaded.root.children.length, 2);
    expect(
      loaded.pos.board.board[loaded.pos.board.loc(8, 8)],
      Board.black,
      reason: 'the branch selected when saved is the imported main line',
    );
    expect(loaded.toSgf(), contains(';B[cc]'));
    expect(loaded.toSgf(), contains(';B[ii]'));
  });

  test('an invalid SGF does not replace the live game', () async {
    final game = ShapeGame(null, boardSize: 9);
    await game.start();
    await game.playAt(2, 2);
    final oldRoot = game.root;

    await expectLater(
      game.loadSgf('(;GM[1]SZ[9];B[cc];W[cc])'),
      throwsA(isA<SgfFormatException>()),
    );
    expect(identical(game.root, oldRoot), isTrue);
    expect(game.cursor, 1);
  });

  test('setup stones become moves and imported rules stay Japanese', () async {
    final game = ShapeGame(null, boardSize: 9);
    await game.start();

    await game.loadSgf('(;GM[1]SZ[9]RU[Chinese]AB[aa:bb]AW[cc];B[dd])');

    expect(game.rules.scoringRule, 'SCORING_TERRITORY');
    expect(game.rules.multiStoneSuicideLegal, isFalse);
    expect(game.line.length, 6);
    expect(game.line.take(4).every((move) => move.pla == Board.black), isTrue);
    expect(game.line[4].pla, Board.white);
    expect(game.pos.board.board[game.pos.board.loc(0, 0)], Board.black);
    expect(game.pos.board.board[game.pos.board.loc(1, 1)], Board.black);
    expect(game.pos.board.board[game.pos.board.loc(2, 2)], Board.white);
    expect(game.pos.board.board[game.pos.board.loc(3, 3)], Board.black);
  });

  test(
    'setup removals are still rejected because they are not moves',
    () async {
      final game = ShapeGame(null, boardSize: 9);
      await game.start();

      await expectLater(
        game.loadSgf('(;GM[1]SZ[9]AE[cc])'),
        throwsA(isA<SgfFormatException>()),
      );
    },
  );

  // Grammar cases adapted from PySGF's parser tests. SHAPE does not port its
  // NGF/GIB readers or typed metadata helpers.
  group('PySGF parser cases', () {
    test('server text before the game tree is ignored', () {
      final root = parseSgf(
        '... 01:23:45 +0900 (JST) ... (;SZ[19];B[aa];W[ba];)',
      );
      expect(root.value('SZ'), '19');
      expect(root.children.single.value('B'), 'aa');
      expect(root.children.single.children.single.value('W'), 'ba');
    });

    test('newlines may separate properties from values and nodes', () {
      final root = parseSgf('\n(\n;\nGM[1]\nDT\n[2020-04-12]\n;\nB\n[dp]\n)\n');
      expect(root.value('DT'), '2020-04-12');
      expect(root.children.single.value('B'), 'dp');
    });

    test('property escapes and line endings follow FF4', () {
      final root = parseSgf('(;C[one\\]two\\\\three\\\nnext\r\nline]XX[a][b])');
      expect(root.value('C'), 'one]two\\threenext\nline');
      expect(root.properties['XX'], ['a', 'b']);
    });

    test('legacy mixed-case property names do not break parsing', () {
      final root = parseSgf('(;CoPyright[old server];B[aa])');
      expect(root.value('COPYRIGHT'), 'old server');
      expect(root.children.single.value('B'), 'aa');
    });
  });

  test('tt is accepted as the old 19x19 pass coordinate', () async {
    final game = ShapeGame(null);
    await game.start();
    await game.loadSgf('(;GM[1]FF[4]SZ[19];B[tt])');
    expect(game.line.single.isPass, isTrue);
  });
}
