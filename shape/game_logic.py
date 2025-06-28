import copy

import numpy as np
from pysgf import SGF, Move, SGFNode

from shape.utils import setup_logging

logger = setup_logging()


class PolicyData:
    @staticmethod
    def grid_from_data(policy_data: list[float] | np.ndarray):
        size = int(len(policy_data) ** 0.5)
        return np.reshape(policy_data[:-1], (size, size))[::-1]

    def __init__(self, policy_data: list[float] | np.ndarray):
        self.data = np.array(policy_data)
        self.grid = self.grid_from_data(self.data)
        self.pass_prob = self.data[-1]
        self.max_prob = np.max(self.data)

    def at(self, move: Move) -> tuple[float, float]:
        if move.is_pass:
            return self.pass_prob, self.pass_prob / self.max_prob
        col, row = move.coords
        return self.grid[row][col], self.grid[row][col] / self.max_prob

    def sample(
        self,
        top_k: int = 10000,
        top_p: float = 1e9,
        min_p: float = 0.0,
        exclude_pass: bool = True,
        secondary_data: np.ndarray | None = None,
    ) -> tuple[list[tuple[Move, float, float]], str]:
        secondary_data_data = secondary_data if secondary_data is not None else self.grid
        moves = [
            (Move(coords=(col, row)), prob, d)
            for row, (policy_row, secondary_data_row) in enumerate(zip(self.grid, secondary_data_data, strict=False))
            for col, (prob, d) in enumerate(zip(policy_row, secondary_data_row, strict=False))
            if prob > 0
        ]
        if self.pass_prob > 0 and not exclude_pass:
            moves.append(("pass", self.pass_prob, None))
        moves.sort(key=lambda x: x[1], reverse=True)
        highest_prob = moves[0][1]
        top_moves = []
        total_prob = 0
        for i, (move, prob, *data) in enumerate(moves, 1):
            if prob < min_p * highest_prob:
                return top_moves, "min_p"
            top_moves.append((move, prob, *data))
            total_prob += prob

            if i == top_k:
                return top_moves, "top_k"
            if total_prob >= top_p:
                return top_moves, "top_p"

        return top_moves, "all"


class Analysis:
    REQUESTED = object()

    def __init__(self, key: str | None, data: dict):
        self.key = key
        self.data = data
        self.ai_policy = PolicyData(data.pop("policy"))
        if "humanPolicy" in data:
            self.human_policy = PolicyData(data.pop("humanPolicy"))
        else:
            assert key is None, f"Expected human policy for key {key}"
            self.human_policy = self.ai_policy

    @property
    def root_info(self) -> dict:
        return self.data.get("rootInfo", {})

    def ai_score(self) -> float | None:
        return self.root_info.get("scoreLead")

    def win_rate(self) -> float | None:
        return self.root_info.get("winrate")

    def visit_count(self) -> int:
        return self.root_info.get("visits", 0)

    def ai_moves(self) -> list:
        return self.data.get("moveInfos", [])


class GameNode(SGFNode):
    def __init__(self, parent: "GameNode | None" = None, properties=None, move=None):
        super().__init__(parent, properties, move)
        if parent:
            assert move is not None
            self.board_state = self._board_state_after_move(parent.board_state, move)
        else:
            bx, by = self.board_size
            self.board_state: list[list[str | None]] = [[None for _ in range(bx)] for _ in range(by)]
        self.analyses = {}
        self.ai_move_requested = False  # flag to indicate if ai move was manually requested
        self.autoplay_halted_reason: str | None = None  # flag to indicate if autoplay was automatically halted

    @property
    def square_board_size(self) -> int:
        bx, by = self.board_size
        assert bx == by, "Non-square board size not supported"
        return bx

    def game_ended(self) -> bool:
        return self.is_pass and self.parent.is_pass

    def delete_child(self, child: "GameNode"):
        self.children = [c for c in self.children if c is not child]

    def _board_state_after_move(self, board_state: list[list[str | None]], move: Move) -> list[list[str | None]]:
        new_board_state = copy.deepcopy(board_state)
        if move.is_pass:
            return new_board_state
        col, row = move.coords
        new_board_state[row][col] = move.player
        captured = self._remove_captured_stones(new_board_state, col, row, move.opponent)
        if captured:
            self._remove_group(new_board_state, captured)
        else:
            group = self._get_group(new_board_state, col, row)
            if not self._group_has_liberties(new_board_state, group):
                self._remove_group(new_board_state, group)  # allow suicide
        return new_board_state

    def _is_valid_move(self, move: Move):
        if move.is_pass:
            return True
        col, row = move.coords
        if not (0 <= row < len(self.board_state) and 0 <= col < len(self.board_state[0])):
            logger.error("Point is out of bounds")
            return False
        if self.board_state[row][col] is not None:
            logger.error("Point is already occupied")
            return False
        return True

    def _remove_captured_stones(self, board_state, col, row, opponent):
        captured = []
        for dcol, drow in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
            ncol, nrow = col + dcol, row + drow
            if 0 <= nrow < len(board_state) and 0 <= ncol < len(board_state[0]) and board_state[nrow][ncol] == opponent:
                group = self._get_group(board_state, ncol, nrow)
                if not self._group_has_liberties(board_state, group):
                    self._remove_group(board_state, group)
                    captured.extend(group)
        return captured

    def _get_group(self, board_state, col, row):
        color = board_state[row][col]
        group = set()
        stack = [(col, row)]
        while stack:
            ccol, crow = stack.pop()
            if (ccol, crow) not in group:
                group.add((ccol, crow))
                for dcol, drow in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
                    ncol, nrow = ccol + dcol, crow + drow
                    if (
                        0 <= nrow < len(board_state)
                        and 0 <= ncol < len(board_state[0])
                        and board_state[nrow][ncol] == color
                    ):
                        stack.append((ncol, nrow))
        return group

    def _has_liberties(self, board_state, col, row):
        for dcol, drow in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
            ncol, nrow = col + dcol, row + drow
            if 0 <= nrow < len(board_state) and 0 <= ncol < len(board_state[0]) and board_state[nrow][ncol] is None:
                return True
        return False

    def _remove_group(self, board_state, group):
        for col, row in group:
            board_state[row][col] = None

    def _group_has_liberties(self, board_state, group):
        return any(self._has_liberties(board_state, col, row) for col, row in group)

    def store_analysis(self, analysis: dict, key: str | None):
        current_analysis = self.get_analysis(key)
        parsed_analysis = Analysis(key, analysis)
        if current_analysis and current_analysis.visit_count() >= parsed_analysis.visit_count():
            return  # ignore if we already have a better analysis
        self.analyses[key] = parsed_analysis

    def mark_analysis_requested(self, key: str | None):
        if key not in self.analyses:
            self.analyses[key] = Analysis.REQUESTED  # requested but not yet received

    def analysis_requested(self, key: str | None):
        return key in self.analyses  # None means requested but not yet received

    def get_analysis(self, key: str | None, parent: bool = False) -> Analysis | None:
        if parent:
            return self.parent.get_analysis(key) if self.parent else None
        analysis = self.analyses.get(key)
        return None if analysis is Analysis.REQUESTED else analysis

    def mistake_size(self) -> float | None:
        current_analysis = self.get_analysis(None)
        parent_analysis = None
        if self.parent:
            parent_analysis = self.parent.get_analysis(None)

        if not current_analysis or not parent_analysis:
            return None

        current_score = current_analysis.ai_score()
        parent_score = parent_analysis.ai_score()
        if current_score is None or parent_score is None:
            return None

        score_diff = current_score - parent_score
        return score_diff if self.player == "W" else -score_diff


class ShapeSGF(SGF):
    _NODE_CLASS = GameNode


class GameLogic:
    def __init__(self):
        self.new_game()

    def new_game(self, board_size=19, **rules):
        self.current_node = GameNode(properties={"RU": "JP", "KM": 6.5, "SZ": board_size, **rules})

    def __getattr__(self, attr):
        if not hasattr(self.current_node, attr):
            raise AttributeError(f"'GameLogic' object has no attribute '{attr}'")
        return getattr(self.current_node, attr)

    def make_move(self, move: Move) -> bool:
        if not self.current_node._is_valid_move(move):
            return False
        self.current_node = self.current_node.play(move)
        return True

    def undo_move(self, n: int = 1):
        while (n := n - 1) >= 0 and self.current_node.parent:
            self.current_node = self.current_node.parent

    def redo_move(self, n: int = 1):
        while (n := n - 1) >= 0 and self.current_node.children:
            self.current_node = self.current_node.children[0]

    def get_score_history(self) -> list[tuple[int, float]]:
        nodes = self.current_node.nodes_from_root
        return [(node.depth, ai_analysis.ai_score()) for node in nodes if (ai_analysis := node.get_analysis(None))]

    def export_sgf(self, player_names):
        return self.current_node.root.sgf()

    def import_sgf(self, sgf_data: str):
        self.current_node = ShapeSGF.parse(sgf_data)
