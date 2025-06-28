import pytest

from shape.game_logic import GameLogic, PolicyData


def test_game_logic_initialization():
    """Test that GameLogic can be initialized."""
    game = GameLogic()
    assert game is not None


def test_game_logic_new_game():
    """Test that new_game works with different board sizes."""
    game = GameLogic()
    game.new_game(board_size=19)
    assert game.current_node.square_board_size == 19

    game.new_game(board_size=13)
    assert game.current_node.square_board_size == 13


@pytest.mark.parametrize("board_size", [9, 13, 19])
def test_valid_board_sizes(board_size):
    """Test that valid board sizes work correctly."""
    game = GameLogic()
    game.new_game(board_size=board_size)
    assert game.current_node.square_board_size == board_size


def test_policy_data_initialization():
    """Test PolicyData initialization."""
    policy_data = [0.1] * 361 + [0.05]  # 19x19 board + pass
    policy = PolicyData(policy_data)
    assert policy.pass_prob == 0.05
    assert policy.grid.shape == (19, 19)


def test_policy_data_grid_from_data():
    """Test PolicyData grid creation."""
    policy_data = [0.1] * 81 + [0.05]  # 9x9 board + pass
    grid = PolicyData.grid_from_data(policy_data)
    assert grid.shape == (9, 9)
