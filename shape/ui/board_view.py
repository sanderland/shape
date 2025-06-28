import numpy as np
from PySide6.QtCore import QPointF, QRectF, QSize, Qt
from PySide6.QtGui import (
    QBrush,
    QColor,
    QFont,
    QPainter,
    QPen,
    QRadialGradient,
)
from PySide6.QtWidgets import QSizePolicy, QWidget

from shape.game_logic import Move, PolicyData
from shape.utils import setup_logging

logger = setup_logging()


def interpolate_color(color1, color2, ratio):
    r = color1.red() + (color2.red() - color1.red()) * ratio
    g = color1.green() + (color2.green() - color1.green()) * ratio
    b = color1.blue() + (color2.blue() - color1.blue()) * ratio
    return QColor(int(r), int(g), int(b))


class BoardView(QWidget):
    WOOD_COLOR = QColor(220, 179, 92)
    PLAYER_POLICY_COLOR = QColor(20, 200, 20)
    TARGET_POLICY_COLOR = QColor(0, 100, 0)
    AI_POLICY_COLOR = QColor(0, 0, 139)
    OPPONENT_POLICY_COLOR = QColor(139, 0, 0)

    def sizeHint(self):
        return QSize(600, 600)

    def __init__(self, main_window, parent=None):
        super().__init__(parent)
        self.main_window = main_window
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self.setMinimumSize(400, 400)

    def calculate_dimensions(self, board_size):
        self.board_size = board_size
        cell_size_h = self.width() / (board_size + 0.5)  # n-1 grid, 1 l 0.5 r
        cell_size_v = self.height() / (board_size + 1.05)  # n-1 grid, 0.5 coord 0.5 btn
        self.cell_size = min(cell_size_h, cell_size_v)
        self.margin_left = self.cell_size
        self.margin_top = self.cell_size * 0.5
        self.margin_bottom = self.cell_size
        self.stone_size = self.cell_size * 0.95
        self.nav_buttons = [
            ("⏮", lambda: self.main_window.on_prev_move(1000), 1.3),
            ("⏪", lambda: self.main_window.on_prev_move(5), 1.3),
            ("◀", lambda: self.main_window.on_prev_move(), 0.9),
            ("pass", lambda: self.main_window.on_pass_move(), 1.0),
            ("▶", lambda: self.main_window.on_next_move(), 0.9),
            ("⏩", lambda: self.main_window.on_next_move(5), 1.3),
            ("⏭", lambda: self.main_window.on_next_move(1000), 1.3),
        ]
        button_width = self.width() / (2 * len(self.nav_buttons))
        self.nav_rects = [
            QRectF(
                self.width() * 0.25 + i * button_width,
                (board_size + 0.275) * self.cell_size,
                button_width,
                self.margin_bottom,
            )
            for i in range(len(self.nav_buttons))
        ]
        self.coord_font_size = max(int(self.cell_size / 3), 8)

    def intersection_coords(self, col, row) -> QPointF:
        x = self.margin_left + col * self.cell_size
        y = self.margin_top + (self.board_size - row - 1) * self.cell_size
        return QPointF(x, y)

    def paintEvent(self, event):
        board_state = self.main_window.game_logic.board_state
        self.calculate_dimensions(self.main_window.game_logic.square_board_size)

        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing, True)
        painter.setRenderHint(QPainter.SmoothPixmapTransform, True)

        self.draw_board(painter)
        self.draw_coordinates_and_nav(painter)
        self.draw_star_points(painter)

        heatmap_settings = self.main_window.control_panel.get_heatmap_settings()
        sampling_settings = self.main_window.config_panel.get_sampling_settings()
        self.draw_heatmap(painter, heatmap_settings["policy"], sampling_settings)

        self.draw_stones(board_state, painter)
        self.draw_game_status(painter)

    def draw_board(self, painter):
        if self.main_window.game_logic.current_node.autoplay_halted_reason:
            color = QColor(self.WOOD_COLOR.red() + 20, self.WOOD_COLOR.green() - 40, self.WOOD_COLOR.blue() - 20)
        else:
            color = self.WOOD_COLOR
        painter.fillRect(self.rect(), color)
        painter.setPen(QPen(QColor(0, 0, 0, 180), 1))
        for i in range(self.board_size):
            painter.drawLine(self.intersection_coords(0, i), self.intersection_coords(self.board_size - 1, i))
            painter.drawLine(self.intersection_coords(i, 0), self.intersection_coords(i, self.board_size - 1))
        painter.setPen(QPen(QColor(0, 0, 0), 2))
        grid_size = self.cell_size * (self.board_size - 1)
        painter.drawRect(QRectF(self.margin_left, self.margin_top, grid_size, grid_size))

    def draw_star_points(self, painter):
        painter.setBrush(QBrush(Qt.black))
        for col, row in self.get_star_points():
            painter.drawEllipse(self.intersection_coords(col, row), 3, 3)

    def draw_stones(self, board_state, painter):
        game_logic = self.main_window.game_logic
        for row in range(self.board_size):
            for col in range(self.board_size):
                if board_state[row][col] is not None:
                    self.draw_stone(painter, row, col, board_state[row][col])

        last_move = game_logic.move
        if last_move and not last_move.is_pass:
            center = self.intersection_coords(*last_move.coords)
            outline_color = QColor(240, 240, 240, 180) if last_move.player == "B" else QColor(50, 50, 50, 180)
            painter.setPen(QPen(outline_color, 2))
            painter.setBrush(Qt.NoBrush)
            painter.drawEllipse(center, self.stone_size / 4, self.stone_size / 4)

    def draw_stone(self, painter, row, col, color):
        center = self.intersection_coords(col, row)

        gradient = QRadialGradient(center.x() - self.stone_size / 4, center.y() - self.stone_size / 4, self.stone_size)
        if color == "B":
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

    def draw_coordinates_and_nav(self, painter):
        font = QFont("Arial", self.coord_font_size, QFont.Bold)
        painter.setFont(font)
        painter.setPen(QColor(0, 0, 0))
        for i in range(self.board_size):
            bottom_box = self.intersection_coords(i - 0.5, -0.5)
            painter.drawText(
                QRectF(bottom_box.x(), bottom_box.y(), self.cell_size, self.cell_size * 0.5),
                Qt.AlignHCenter | Qt.AlignTop,
                Move.GTP_COORD[i],
            )
            left_box = self.intersection_coords(-1, i + 0.5)
            painter.drawText(
                QRectF(left_box.x(), left_box.y(), self.cell_size * 0.5, self.cell_size),
                Qt.AlignVCenter | Qt.AlignRight,
                str(i + 1),
            )
        for (text, _, size_adj), nav_rect in zip(self.nav_buttons, self.nav_rects, strict=False):
            painter.setFont(QFont("Arial", self.coord_font_size * size_adj, QFont.Bold))
            painter.drawText(nav_rect, Qt.AlignCenter, text)

    def mousePressEvent(self, event):
        for (_, callback, _), rect in zip(self.nav_buttons, self.nav_rects, strict=False):
            if rect.contains(event.pos()):
                callback()
                return
        col = round((event.x() - self.margin_left) / self.cell_size)
        row = round((event.y() - self.margin_top) / self.cell_size)
        if 0 <= col < self.board_size and 0 <= row < self.board_size:
            self.main_window.make_move((col, self.board_size - row - 1))

    def get_star_points(self):
        star_points = {
            19: [(3, 3), (3, 9), (3, 15), (9, 3), (9, 9), (9, 15), (15, 3), (15, 9), (15, 15)],
            13: [(3, 3), (3, 9), (6, 6), (9, 3), (9, 9)],
            9: [(2, 2), (2, 6), (4, 4), (6, 2), (6, 6)],
        }
        return star_points.get(self.board_size, [])

    def get_weighted_policy_data(self, human_profiles: list[str]) -> tuple[np.ndarray | None, np.ndarray]:
        game_logic = self.main_window.game_logic
        heatmap_mean_prob = None
        heatmap_mean_rank = np.array([])  # make type hints happy
        num_enabled = 0

        for i, (profile, enabled) in enumerate(human_profiles):
            if not (analysis := game_logic.current_node.get_analysis(profile)):
                continue
            policy = np.array(analysis.human_policy.data)
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

    def draw_heatmap(self, painter, policy, sampling_settings):
        heatmap_mean_prob, heatmap_mean_rank = self.get_weighted_policy_data(policy)
        if (
            self.main_window.game_logic.move
            and self.main_window.game_logic.move.is_pass
            and self.main_window.game_logic.current_node.parent.parent is None
        ):
            prob_gradient = np.tile(np.linspace(0.01, 1, self.board_size), (self.board_size, 1))
            rank_gradient = np.tile(np.linspace(0, 2, self.board_size), (self.board_size, 1)).T
            heatmap_mean_prob = np.append(prob_gradient.ravel(), 0)
            heatmap_mean_rank = np.append(rank_gradient.ravel(), 0)
            sampling_settings = {"min_p": 0}

        if heatmap_mean_prob is not None:
            top_moves, _ = PolicyData(heatmap_mean_prob).sample(
                secondary_data=PolicyData.grid_from_data(heatmap_mean_rank), **sampling_settings
            )
            self.draw_heatmap_points(painter, top_moves)

    def draw_heatmap_points(self, painter, top_moves, show_text=True):
        max_prob = top_moves[0][1]
        for move, prob, rank in top_moves:
            color = self.get_heatmap_color(rank)
            rel_prob = prob / max_prob
            size = 0.25 + 0.725 * rel_prob
            center = self.intersection_coords(*move.coords)
            x = center.x() - size / 2
            y = center.y() - size / 2

            text = "" if rel_prob < 0.01 else f"{prob * 100:.0f}"

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

    def get_heatmap_color(self, mean_rank):
        if mean_rank < 1:  # Interpolate between Light Green and Dark Green
            ratio = mean_rank / 1
            return interpolate_color(self.PLAYER_POLICY_COLOR, self.TARGET_POLICY_COLOR, ratio)
        elif mean_rank <= 2:  # Interpolate between Dark Green and Dark Blue
            ratio = min(1, (mean_rank - 1) / 1)
            return interpolate_color(self.TARGET_POLICY_COLOR, self.AI_POLICY_COLOR, ratio)
        else:
            return self.OPPONENT_POLICY_COLOR

    def draw_game_status(self, painter):
        game_logic = self.main_window.game_logic
        message = ""
        if game_logic.game_ended():
            message = "Both players passed."
        elif game_logic.current_node.move and game_logic.current_node.move.is_pass:
            message = "Pass"

        if message:
            font = QFont("Arial", int(self.cell_size * 0.4))
            font.setBold(True)
            painter.setFont(font)
            painter.setPen(QColor(0, 0, 0))
            text_rect = QRectF(0, 0, self.width(), self.margin_top)
            painter.drawText(text_rect, Qt.AlignCenter, message)

    def keyPressEvent(self, event):
        if event.key() == Qt.Key_Left:
            if event.modifiers() & Qt.ShiftModifier:
                self.main_window.on_prev_move(5)
            else:
                self.main_window.on_prev_move()
        elif event.key() == Qt.Key_Right:
            if event.modifiers() & Qt.ShiftModifier:
                self.main_window.on_next_move(5)
            else:
                self.main_window.on_next_move()
        elif event.key() == Qt.Key_Space:
            self.main_window.on_pass_move()
        else:
            super().keyPressEvent(event)
