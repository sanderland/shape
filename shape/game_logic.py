import re
from typing import Any, Dict, List, Optional, Tuple

import numpy as np

from shape.utils import setup_logging

logger = setup_logging()


def get_top_moves(
    policy: np.ndarray | List[float],
    board_size: int,
    secondary_data: tuple[np.ndarray, ...] = (),
    top_k: int = 10000,
    top_p: float = 1e9,
    min_p: float = 0.0,
    exclude_pass: bool = True,
) -> Tuple[List[Tuple[str, float]], str]:

    size = board_size
    moves = []
    for i, prob in enumerate(policy[:-1]):  # Exclude the last element (pass)
        if prob > 0:
            row = i // size
            col = i % size
            move = GameNode.rowcol_to_gtp(row, col, size)
            moves.append((move, prob) + tuple(d[i] for d in secondary_data))
    if policy[-1] > 0 and not exclude_pass:  # Add pass move if its probability is positive
        moves.append(("pass", policy[-1]) + tuple(d[-1] for d in secondary_data))

    moves.sort(key=lambda x: x[1], reverse=True)

    total_prob = 0
    top_moves = []
    highest_prob = moves[0][1] if moves else 0

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

    def ai_score(self) -> float | None:
        return self.data.get("rootInfo", {}).get("scoreLead")

    def win_rate(self) -> float | None:
        return self.data.get("rootInfo", {}).get("winrate")

    def top_moves(self) -> List[Dict[str, Any]]:
        return self.data.get("moveInfos", [])

    def visit_count(self) -> int:
        return self.data.get("rootInfo", {}).get("visits", 0)

    def _process_policy(self, policy: List[float], process: bool = True) -> List[Tuple[str, float]] | List[float]:
        if not policy:
            return []
        if not process:
            return policy
        moves = []
        size = int(len(policy) ** 0.5)
        for i, prob in enumerate(policy[:-1]):  # Exclude the last element (pass)
            if prob > 0:
                row = i // size
                col = i % size
                move = GameNode.rowcol_to_gtp(row, col, size)
                moves.append((move, prob))
        if policy[-1] > 0:  # Add pass move if its probability is positive
            moves.append(("pass", policy[-1]))
        return sorted(moves, key=lambda x: x[1], reverse=True)

    def human_policy(self, process: bool = True) -> List[Tuple[str, float]] | List[float]:
        if self.key is None:
            return self.ai_policy(process)
        else:
            return self._process_policy(self.data["humanPolicy"], process)

    def ai_policy(self, process: bool = True) -> List[Tuple[str, float]] | List[float]:
        return self._process_policy(self.data["policy"], process)

    def get_top_moves(self, top_k, top_p, min_p) -> Tuple[List[Tuple[str, float]], str]:
        policy_data = self.human_policy()
        total_prob = 0
        top_moves = []

        highest_prob = policy_data[0][1]
        for i, (move, prob) in enumerate(policy_data, 1):
            if move == "pass":
                continue

            if prob < min_p * highest_prob:
                return top_moves, "min_p"

            top_moves.append((move, prob))
            total_prob += prob

            if i == top_k:
                return top_moves, "top_k"
            if i == top_k or total_prob >= top_p:
                return top_moves, "top_p"

        return top_moves, "all"

    def move_probability(self, move: str) -> Tuple[float, float]:
        policy = self.human_policy()
        highest_prob = policy[0][1]
        for m, prob in policy:
            if m == move:
                return prob, prob / highest_prob
        return 0.0, 0.0


class GameNode:
    def __init__(
        self,
        board_state: List[List[str | None]],
        move: Optional[Tuple[str, str]] = None,
        parent: Optional["GameNode"] = None,
    ):
        self.board_state = board_state
        self.move = move
        self.parent = parent
        self.children = []
        self.analyses = {}
        self.ai_move_requested = False  # flag to indicate if ai move was manually requested
        self.autoplay_halted_reason = None  # flag to indicate if autoplay was automatically halted

    @property
    def player(self) -> str | None:
        if self.move is None:
            return "W"  # root node, only used for determining opponent-opponent color
        return self.move[0]

    @property
    def coords(self) -> str | None:
        if self.move is None:
            return None
        return self.move[1]

    @property
    def opponent_color(self) -> str:
        if self.move is None:
            return "B"  # root node
        return "W" if self.move[0] == "B" else "B"

    def __repr__(self):
        return f"<GameNode move={''.join(self.move) if self.move else 'root'}>"

    @property
    def board_size(self):
        return len(self.board_state)

    @staticmethod
    def gtp_to_rowcol(move_str: str, board_size: int) -> Tuple[Optional[int], Optional[int]]:
        if move_str == "pass":
            return None, None

        col = ord(move_str[0].upper()) - ord("A")
        if col >= 8:  # Adjust for skipping 'I'
            col -= 1
        row = int(move_str[1:]) - 1

        return row, col

    @staticmethod
    def rowcol_to_gtp(row: int, col: int, board_size: int) -> str:
        col_str = chr(ord("A") + col + (1 if col >= 8 else 0))
        row_str = str(board_size - row)
        return f"{col_str}{row_str}"

    def make_move(self, move: str, player: str | None = None) -> Optional["GameNode"]:
        row, col = self.gtp_to_rowcol(move, self.board_size)
        if player is None:
            player = self.opponent_color

        if row is None or col is None:
            logger.info(f"Pass move made")
            new_node = GameNode(self.board_state, (player, "pass"), self)
            self.children.append(new_node)
            return new_node

        if self._is_valid_move(row, col):
            for child in self.children:
                if child.move == (player, move):
                    logger.debug(f"Move already exists: {move}")
                    return child

            new_board_state = [row[:] for row in self.board_state]
            new_board_state[row][col] = player
            captured = self._remove_captured_stones(new_board_state, row, col, self.player)

            if not captured:
                group = self._get_group(new_board_state, row, col)
                if not self._group_has_liberties(new_board_state, group):
                    logger.error(f"Suicide move detected: {move}")
                    return None

            player = self.opponent_color
            new_node = GameNode(new_board_state, (player, move), self)
            self.children.append(new_node)
            logger.info(f"Move made: {move}, Captured: {len(captured)}")
            return new_node
        else:
            logger.error(f"Move is not valid: {move}")
        return None

    def _is_valid_move(self, row, col):
        if not (0 <= row < self.board_size and 0 <= col < self.board_size):
            logger.error("Point is out of bounds")
            return False
        if self.board_state[row][col] is not None:
            logger.error("Point is already occupied")
            return False
        # TODO: Implement ko rule
        return True

    def _remove_captured_stones(self, board_state, row, col, opponent):
        captured = []
        for drow, dcol in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
            nrow, ncol = row + drow, col + dcol
            if 0 <= nrow < self.board_size and 0 <= ncol < self.board_size:
                if board_state[nrow][ncol] == opponent:
                    group = self._get_group(board_state, nrow, ncol)
                    if not self._group_has_liberties(board_state, group):
                        self._remove_group(board_state, group)
                        captured.extend(group)
        return captured

    def _get_group(self, board_state, row, col):
        color = board_state[row][col]
        group = set()
        stack = [(row, col)]
        while stack:
            crow, ccol = stack.pop()
            if (crow, ccol) not in group:
                group.add((crow, ccol))
                for drow, dcol in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
                    nrow, ncol = crow + drow, ccol + dcol
                    if 0 <= nrow < self.board_size and 0 <= ncol < self.board_size:
                        if board_state[nrow][ncol] == color:
                            stack.append((nrow, ncol))
        return group

    def _has_liberties(self, board_state, row, col):
        for drow, dcol in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
            nrow, ncol = row + drow, col + dcol
            if 0 <= nrow < self.board_size and 0 <= ncol < self.board_size:
                if board_state[nrow][ncol] is None:
                    return True
        return False

    def _remove_group(self, board_state, group):
        for row, col in group:
            board_state[row][col] = None

    def _group_has_liberties(self, board_state, group):
        for row, col in group:
            if self._has_liberties(board_state, row, col):
                return True
        return False

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

    def calculate_mistake_size(self) -> float | None:
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

    def delete_child(self, child_node: "GameNode"):
        if child_node in self.children:
            self.children.remove(child_node)
            return True
        return False


    @property
    def node_history(self):
        history = []
        node = self
        while node:
            history.append(node)
            node = node.parent
        return list(reversed(history))

    @property
    def move_history(self):
        return [node.move for node in self.node_history if node.move]


class GameLogic:
    def __init__(self):
        self.new_game()

    def new_game(self, board_size=19):
        initial_board = [[None for _ in range(board_size)] for _ in range(board_size)]
        self.root = GameNode(initial_board)
        self.current_node = self.root
        self.rules = {"rules": "japanese", "komi": 6.5}

    @property
    def board_size(self):
        return self.current_node.board_size

    def make_move(self, move, player: str | None = None) -> bool:
        new_node = self.current_node.make_move(move, player)
        if new_node:
            self.current_node = new_node
            return True
        return False

    def undo_move(self) -> bool:
        if self.current_node.parent:
            self.current_node = self.current_node.parent
            return True
        return False

    def redo_move(self) -> bool:
        if self.current_node.children:
            self.current_node = self.current_node.children[0]
            return True
        return False

    def current_player_color(self):
        return self.current_node.player

    def get_settings(self):
        return {**self.rules, "boardXSize": self.current_node.board_size, "boardYSize": self.current_node.board_size}

    @property
    def board_state(self):
        return self.current_node.board_state

    def get_score_history(self) -> list[float]:
        score = []
        node = self.current_node
        while node:
            analysis = node.get_analysis(None)
            if analysis:
                score.append(analysis.ai_score())
            else:
                score.append(None)
            node = node.parent
        return score[::-1]

    def game_over(self) -> bool:
        move_history = self.current_node.move_history
        if len(move_history) < 2:
            return False
        return move_history[-1][1] == "pass" and move_history[-2][1] == "pass"

    def export_sgf(self, player_names):
        sgf_content = "(;GM[1]FF[4]CA[UTF-8]AP[HumanGo]"
        sgf_content += f"SZ[{self.board_size}]"

        # Add player information
        sgf_content += f"PB[{player_names['B']}]PW[{player_names['W']}]"

        for bw, coords in self.current_node.move_history:
            if coords == "pass":
                sgf_content += f";{bw}[]"
            else:
                row, col = GameNode.gtp_to_rowcol(coords, self.board_size)
                col_str = chr(ord("a") + col)
                row_str = chr(ord("a") + self.board_size - 1 - row)
                sgf_content += f";{bw}[{col_str}{row_str}]"

        sgf_content += ")"
        return sgf_content

    def import_sgf(self, sgf_data: str) -> bool:
        try:
            board_size_pattern = r"SZ\[(\d+)\]"
            board_size_match = re.search(board_size_pattern, sgf_data)
            if board_size_match:
                board_size = int(board_size_match.group(1))
            else:
                logger.error("Board size not found in SGF data")
                return False
            move_pattern = r";([BW])\[(.*?)\]"
            moves = re.findall(move_pattern, sgf_data)
            self.new_game(board_size)
            for color, coords in moves:
                row = ord(coords[1]) - ord("a")
                col = ord(coords[0]) - ord("a")
                move = GameNode.rowcol_to_gtp(row, col, self.board_size)
                self.make_move(move, player=color)
            return True
        except Exception as e:
            logger.error(f"Failed to import SGF: {e}")
            return False

    def get_top_moves(
        self, policy: str, top_k: int = 1000, top_p: float = 1.0, min_p: float = 0.0
    ) -> Tuple[List[Tuple[str, float]], str]:
        analysis = self.current_node.get_analysis(policy)
        if not analysis:
            return [], "no_analysis"
        policy_data = analysis.human_policy(process=False)
        return get_top_moves(policy_data, self.board_size, top_k=top_k, top_p=top_p, min_p=min_p)

    def sample_move(self, moves: List[Tuple[str, float]]) -> str:
        if not moves:
            return "pass"
        moves, probs = zip(*moves)
        probs = np.array(probs) / sum(probs)  # Normalize probabilities
        return np.random.choice(moves, p=probs)
