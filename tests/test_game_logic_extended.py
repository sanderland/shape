import numpy as np

from shape.game_logic import GameLogic, Move, PolicyData


def test_policy_data_sample_top_k():
    policy = list(np.linspace(0.1, 0.01, 9))  # 3x3 board
    policy_data = policy + [0.0]  # pass
    p = PolicyData(policy_data)
    moves, reason = p.sample(top_k=5)
    assert reason == "top_k"
    assert len(moves) == 5
    assert moves[0][1] > moves[1][1]


def test_policy_data_sample_top_p():
    policy = [0.5, 0.3, 0.1, 0.05, 0.05, 0.0, 0.0, 0.0, 0.0]  # 3x3 board
    policy_data = policy + [0.0]  # pass
    p = PolicyData(np.array(policy_data))
    moves, reason = p.sample(top_p=0.8)
    assert reason == "top_p"
    assert len(moves) == 2


def test_policy_data_sample_min_p():
    policy = [0.5, 0.3, 0.1, 0.05, 0.05, 0.0, 0.0, 0.0, 0.0]  # 3x3 board
    policy_data = policy + [0.0]
    p = PolicyData(np.array(policy_data))
    moves, reason = p.sample(min_p=0.3)
    assert reason == "min_p"
    assert len(moves) == 2
    assert moves[0][1] == 0.5
    assert moves[1][1] == 0.3


def test_game_logic_capture_single_stone():
    game = GameLogic()
    game.new_game(board_size=5)
    game.make_move(Move(coords=(1, 1), player="B"))
    game.make_move(Move(coords=(0, 1), player="W"))
    game.make_move(Move(coords=(2, 2), player="B"))  # filler
    game.make_move(Move(coords=(1, 0), player="W"))
    game.make_move(Move(coords=(3, 3), player="B"))  # filler
    game.make_move(Move(coords=(2, 1), player="W"))
    game.make_move(Move(coords=(4, 4), player="B"))  # filler
    # Now W plays at (1,2) to capture B at (1,1)
    assert game.board_state[1][1] == "B"
    game.make_move(Move(coords=(1, 2), player="W"))
    assert game.board_state[1][1] is None  # B stone captured


def test_sgf_import_export():
    game = GameLogic()
    game.new_game(board_size=9)
    game.make_move(Move(coords=(4, 4), player="B"))
    game.make_move(Move(coords=(3, 3), player="W"))
    sgf_data = game.export_sgf(player_names={"B": "Human", "W": "AI"})

    new_game = GameLogic()
    assert new_game.import_sgf(sgf_data)
    assert new_game.board_size == (9, 9)
    assert new_game.current_node.move is not None
    assert new_game.current_node.move.coords == (3, 3)
    assert new_game.current_node.parent is not None
    assert new_game.current_node.parent.move is not None
    assert new_game.current_node.parent.move.coords == (4, 4)
    assert new_game.board_state[4][4] == "B"
    assert new_game.board_state[3][3] == "W"

    # Test with pass
    game.make_move(Move(coords=None, player="B"))
    sgf_data_pass = game.export_sgf(player_names={"B": "Human", "W": "AI"})
    assert "B[]" in sgf_data_pass or "B[tt]" in sgf_data_pass
    assert new_game.import_sgf(sgf_data_pass)
    assert new_game.current_node.is_pass
