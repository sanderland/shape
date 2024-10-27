import numpy as np
from PySide6.QtCore import QPointF, QRectF, QSize, Qt, Signal
from PySide6.QtGui import (
    QBrush,
    QColor,
    QFont,
    QLinearGradient,
    QPainter,
    QPen,
    QRadialGradient,
)
from PySide6.QtWidgets import QSizePolicy, QWidget

from shape.game_logic import GameNode, get_top_moves
from shape.utils import setup_logging

logger = setup_logging()


class BoardView(QWidget):
    move_made = Signal(str)
    WOOD_COLOR = QColor(220, 179, 92)
    PLAYER_POLICY_COLOR = QColor(20, 200, 20)
    TARGET_POLICY_COLOR = QColor(0, 100, 0)
    AI_POLICY_COLOR = QColor(0, 0, 139)
    OPPONENT_POLICY_COLOR = QColor(139, 0, 0)

    def __init__(self, main_window: "MainWindow", parent=None):
        super().__init__(parent)
        self.main_window = main_window
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self.setMinimumSize(400, 400)

    def calculate_dimensions(self, board_size):
        self.board_size = board_size
        size = min(self.width(), self.height())
        self.cell_size = size / (board_size + 0.5)  # n-1 grid, 1 l 0.5 r
        self.margin_left = self.cell_size
        self.margin_top = self.cell_size * 0.5
        self.stone_size = self.cell_size * 0.95

    def intersection_coords(self, row, col) -> QPointF:
        x = self.margin_left + col * self.cell_size
        y = self.margin_top + (self.board_size - row - 1) * self.cell_size
        return QPointF(x, y)

    def paintEvent(self, event):
        board_state = self.main_window.game_logic.board_state
        self.calculate_dimensions(self.main_window.game_logic.board_size)

        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing, True)
        painter.setRenderHint(QPainter.SmoothPixmapTransform, True)

        self.draw_wood_texture(
            painter, redden=self.main_window.game_logic.current_node.autoplay_halted_reason is not None
        )
        self.draw_grid(painter)
        self.draw_coordinates(painter)
        self.draw_star_points(painter)

        heatmap_settings = self.main_window.control_panel.get_heatmap_settings()
        sampling_settings = self.main_window.config_panel.get_sampling_settings()
        self.draw_heatmap(painter, heatmap_settings["policy"], True, sampling_settings)

        self.draw_stones(board_state, painter)

        self.draw_game_status(painter)

    def draw_wood_texture(self, painter, redden=False):
        if redden:
            color = QColor(self.WOOD_COLOR.red() + 20, self.WOOD_COLOR.green() - 40, self.WOOD_COLOR.blue() - 20)
        else:
            color = self.WOOD_COLOR
        painter.fillRect(self.rect(), color)

    def draw_grid(self, painter):
        grid_size = self.cell_size * (self.board_size - 1)
        grid_rect = QRectF(self.margin_left, self.margin_top, grid_size, grid_size)
        painter.setPen(QPen(QColor(0, 0, 0, 180), 1))
        for i in range(self.board_size):
            painter.drawLine(self.intersection_coords(i, 0), self.intersection_coords(i, self.board_size - 1))
            painter.drawLine(self.intersection_coords(0, i), self.intersection_coords(self.board_size - 1, i))
        painter.setPen(QPen(QColor(0, 0, 0), 2))
        painter.drawRect(grid_rect)

    def draw_star_points(self, painter):
        painter.setBrush(QBrush(Qt.black))
        for x, y in self.get_star_points():
            painter.drawEllipse(self.intersection_coords(y, x), 3, 3)

    def draw_stones(self, board_state, painter):
        game_logic = self.main_window.game_logic
        for y in range(self.board_size):
            for x in range(self.board_size):
                if board_state[y][x] is not None:
                    self.draw_stone(painter, x, y, Qt.black if board_state[y][x] == "B" else Qt.white)

        last_move = game_logic.current_node.move
        if last_move and last_move[1] != "pass":
            y, x = game_logic.current_node.gtp_to_rowcol(last_move[1], self.board_size)
            yc = self.board_size - y - 1
            center = QPointF(self.margin_left + x * self.cell_size, self.margin_top + yc * self.cell_size)

            # Inner circle for last move
            if board_state[y][x] == "B":  # Black stone
                painter.setPen(QPen(QColor(240, 240, 240, 180), 2))  # Soft light gray outline
            else:  # White stone
                painter.setPen(QPen(QColor(50, 50, 50, 180), 2))  # Soft dark gray outline

            painter.setBrush(Qt.NoBrush)
            painter.drawEllipse(center, self.stone_size / 4, self.stone_size / 4)

    def draw_stone(self, painter, x, y, color):
        center = self.intersection_coords(y, x)

        gradient = QRadialGradient(center.x() - self.stone_size / 4, center.y() - self.stone_size / 4, self.stone_size)
        if color == Qt.black:
            gradient.setColorAt(0, QColor(80, 80, 80))
            gradient.setColorAt(0.5, Qt.black)
            gradient.setColorAt(1, QColor(10, 10, 10))
        else:
            gradient.setColorAt(0, QColor(230, 230, 230))
            gradient.setColorAt(0.5, Qt.white)
            gradient.setColorAt(1, QColor(200, 200, 200))

        painter.setBrush(QBrush(gradient))
        painter.setPen(Qt.NoPen)
        painter.drawEllipse(center, self.stone_size / 2, self.stone_size / 2)

        # Add shine effect
        shine_gradient = QLinearGradient(
            center.x() - self.stone_size / 4,
            center.y() - self.stone_size / 4,
            center.x() + self.stone_size / 4,
            center.y() + self.stone_size / 4,
        )
        shine_gradient.setColorAt(0, QColor(255, 255, 255, 120))
        shine_gradient.setColorAt(1, QColor(255, 255, 255, 0))
        painter.setBrush(QBrush(shine_gradient))
        painter.drawEllipse(center, self.stone_size / 2 - 2, self.stone_size / 2 - 2)

    def draw_coordinates(self, painter):
        font_size = max(int(self.cell_size / 3), 8)
        font = QFont("Arial", font_size)
        font.setBold(True)
        painter.setFont(font)
        painter.setPen(QColor(0, 0, 0))
        for i in range(self.board_size):
            bottom_box = self.intersection_coords(-0.5, i - 0.5)
            painter.drawText(
                QRectF(bottom_box.x(), bottom_box.y(), self.cell_size, self.cell_size * 0.5),
                Qt.AlignHCenter | Qt.AlignTop,
                GameNode.rowcol_to_gtp(0, i, 0)[0],
            )
            left_box = self.intersection_coords(i + 0.5, -1)
            painter.drawText(
                QRectF(left_box.x(), left_box.y(), self.cell_size * 0.5, self.cell_size),
                Qt.AlignVCenter | Qt.AlignRight,
                str(i + 1),
            )

    def mousePressEvent(self, event):
        col = round((event.x() - self.margin_left) / self.cell_size)
        row = round((event.y() - self.margin_top) / self.cell_size)
        if 0 <= col < self.board_size and 0 <= row < self.board_size:
            move = self.main_window.game_logic.current_node.rowcol_to_gtp(row, col, self.board_size)
            self.move_made.emit(move)

    def get_star_points(self):
        if self.board_size == 19:
            return [(3, 3), (3, 9), (3, 15), (9, 3), (9, 9), (9, 15), (15, 3), (15, 9), (15, 15)]
        elif self.board_size == 13:
            return [(3, 3), (3, 9), (6, 6), (9, 3), (9, 9)]
        elif self.board_size == 9:
            return [(2, 2), (2, 6), (4, 4), (6, 2), (6, 6)]
        else:
            return []

    def sizeHint(self):
        return QSize(600, 600)

    def get_weighted_policy_data(self, policy):
        game_logic = self.main_window.game_logic

        heatmap_mean_prob = heatmap_mean_rank = None
        heatmap_mean_rank = np.array([])  # make type hints happy
        num_enabled = 0

        for i, (policy, enabled) in enumerate(policy):
            if not (analysis := game_logic.current_node.get_analysis(policy)):
                continue
            policy = np.array(analysis.human_policy(process=False))
            if enabled:
                num_enabled += 1
                if heatmap_mean_prob is None:
                    heatmap_mean_prob = np.zeros_like(policy)
                    heatmap_mean_rank = np.zeros_like(policy)
                heatmap_mean_prob += policy
                heatmap_mean_rank += policy * i
        if heatmap_mean_prob is not None:
            heatmap_mean_rank /= heatmap_mean_prob.clip(min=1e-10)
            heatmap_mean_prob /= num_enabled

        return heatmap_mean_prob, heatmap_mean_rank

    def draw_heatmap(self, painter, policy, show_text, sampling_settings):
        heatmap_mean_prob, heatmap_mean_rank = self.get_weighted_policy_data(policy)

        if (
            self.main_window.game_logic.current_node.move
            and self.main_window.game_logic.current_node.move[1] == "pass"
            and self.main_window.game_logic.current_node.parent.parent is None
        ):
            # Create gradients for probability (left to right) and rank (top to bottom)
            prob_gradient = np.tile(np.linspace(0, 1, self.board_size), (self.board_size, 1))
            rank_gradient = np.tile(np.linspace(0, 2, self.board_size), (self.board_size, 1)).T

            heatmap_mean_prob = prob_gradient.ravel()
            heatmap_mean_rank = rank_gradient.ravel()
            sampling_settings = dict(min_p=0)

        if heatmap_mean_prob is not None:
            top_moves, _ = get_top_moves(
                heatmap_mean_prob, self.board_size, secondary_data=(heatmap_mean_rank,), **sampling_settings
            )
            self.draw_heatmap_points(painter, top_moves)

    def draw_heatmap_points(self, painter, top_moves, show_text=True):
        max_prob = top_moves[0][1]
        for move, prob, rank in top_moves:
            row, col = self.main_window.game_logic.current_node.gtp_to_rowcol(move, self.board_size)
            color = self.get_heatmap_color(rank)
            self.draw_heatmap_point(painter, row, col, prob, max_prob, rank, color, show_text)

    def get_heatmap_color(self, mean_rank):
        if mean_rank < 1:  # Interpolate between Light Green and Dark Green
            ratio = mean_rank / 1
            return self.interpolate_color(self.PLAYER_POLICY_COLOR, self.TARGET_POLICY_COLOR, ratio)
        elif mean_rank <= 2:  # Interpolate between Dark Green and Dark Blue
            ratio = min(1, (mean_rank - 1) / 1)
            return self.interpolate_color(self.TARGET_POLICY_COLOR, self.AI_POLICY_COLOR, ratio)
        else:
            return self.OPPONENT_POLICY_COLOR

    def interpolate_color(self, color1, color2, ratio):
        r = color1.red() + (color2.red() - color1.red()) * ratio
        g = color1.green() + (color2.green() - color1.green()) * ratio
        b = color1.blue() + (color2.blue() - color1.blue()) * ratio
        return QColor(int(r), int(g), int(b))

    def draw_heatmap_point(self, painter, row, col, total_prob, max_prob, mean_rank, color, show_text):
        rel_prob = total_prob / max_prob
        size = 0.25 + 0.725 * rel_prob
        x = self.margin_left + col * self.cell_size
        y = self.margin_top + (self.board_size - row - 1) * self.cell_size

        if rel_prob < 0.01:
            text = ""
        else:
            text = f"{total_prob*100:.0f}"

        painter.setBrush(QBrush(color))
        painter.setPen(QPen(Qt.black))
        square_size = self.cell_size * size
        painter.drawRect(QRectF(x - square_size / 2, y - square_size / 2, square_size, square_size))

        if show_text:
            font = QFont("Arial", int(self.cell_size / 3.5))
            font.setBold(True)
            painter.setFont(font)
            painter.setPen(QColor(200, 200, 200))
            painter.drawText(
                QRectF(x - self.cell_size / 2, y - self.cell_size / 2, self.cell_size, self.cell_size),
                Qt.AlignCenter,
                text,
            )

    def draw_game_status(self, painter):
        game_logic = self.main_window.game_logic
        current_node = game_logic.current_node

        message = ""
        if game_logic.game_over():
            message = "Both players passed."
        elif current_node.move and current_node.move[1] == "pass":
            message = "Pass"

        if message:
            font = QFont("Arial", int(self.cell_size * 0.4))
            font.setBold(True)
            painter.setFont(font)
            painter.setPen(QColor(0, 0, 0))
            text_rect = QRectF(0, 0, self.width(), self.margin_top)
            painter.drawText(text_rect, Qt.AlignCenter, message)
