import numpy as np
from PySide6.QtCore import QEvent, QPointF, QRectF, QSize, Qt, Signal
from PySide6.QtGui import QBrush, QColor, QFont, QLinearGradient, QPainter, QPen, QRadialGradient
from PySide6.QtWidgets import QSizePolicy, QWidget

from shape.game_logic import GameLogic
from shape.utils import setup_logging

logger = setup_logging()


class BoardView(QWidget):
    move_made = Signal(str)
    WOOD_COLOR = QColor(220, 179, 92)

    def __init__(self, main_window: "MainWindow", parent=None):
        super().__init__(parent)
        self.main_window = main_window
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self.setMinimumSize(400, 400)

    def calculate_dimensions(self, board_size):
        self.board_size = board_size
        size = min(self.width(), self.height())
        margin_side = int(size * 0.07)
        extra_width = self.width() - size
        extra_height = self.height() - size
        self.margin_left = margin_side + extra_width // 2
        self.margin_right = margin_side + extra_width - extra_width // 2
        self.margin_top = margin_side + extra_height // 2
        self.margin_bottom = margin_side + extra_height - extra_height // 2
        self.cell_size = (size - 2 * margin_side) / (board_size - 1)
        self.stone_size = int(self.cell_size * 0.95)

    def paintEvent(self, event):
        board_state = self.main_window.game_logic.board_state
        self.calculate_dimensions(self.main_window.game_logic.board_size)

        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)

        self.draw_wood_texture(painter, redden=self.main_window.game_logic.current_node.autoplay_halted)
        self.draw_grid(painter)
        self.draw_coordinates(painter)
        self.draw_star_points(painter)

        heatmap_settings = self.main_window.control_panel.get_heatmap_settings()
        if heatmap_settings["enabled"]:
            sampling_settings = self.main_window.config_panel.get_sampling_settings()
            self.draw_heatmap(painter, heatmap_settings["policy"], heatmap_settings["text"], sampling_settings)

        self.draw_stones(board_state, painter)

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
            x = self.margin_left + i * self.cell_size
            y = self.margin_top + i * self.cell_size
            painter.drawLine(QPointF(x, self.margin_top), QPointF(x, self.margin_top + grid_size))
            painter.drawLine(QPointF(self.margin_left, y), QPointF(self.margin_left + grid_size, y))
        painter.setPen(QPen(QColor(0, 0, 0), 2))
        painter.drawRect(grid_rect)

    def draw_star_points(self, painter):
        painter.setBrush(QBrush(Qt.black))
        for x, y in self.get_star_points():
            painter.drawEllipse(
                QPointF(self.margin_left + x * self.cell_size, self.margin_top + y * self.cell_size), 3, 3
            )

    def draw_stones(self, board_state, painter):
        game_logic = self.main_window.game_logic
        for y in range(self.board_size):
            for x in range(self.board_size):
                if board_state[y][x] is not None:
                    self.draw_stone(painter, x, y, Qt.black if board_state[y][x] == "B" else Qt.white)

        last_move = game_logic.current_node.move
        if last_move and last_move[1].lower() != "pass":
            y, x = game_logic.current_node.bw_to_rowcol(last_move[1], self.board_size)
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
        y = self.board_size - y - 1
        center = QPointF(self.margin_left + x * self.cell_size, self.margin_top + y * self.cell_size)

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
        painter.setFont(QFont("Arial", font_size))
        painter.setPen(QColor(0, 0, 0))
        for i in range(self.board_size):
            letter = chr(65 + i) if i < 8 else chr(66 + i)
            number = str(self.board_size - i)
            # Draw letters at the bottom
            painter.drawText(
                self.margin_left + i * self.cell_size - font_size / 3,
                self.margin_top + self.cell_size * (self.board_size - 1) + font_size * 1.5,
                letter,
            )
            # Draw numbers on the left, right-aligned
            text_width = painter.fontMetrics().horizontalAdvance(number + "x")
            painter.drawText(
                self.margin_left - text_width, self.margin_top + i * self.cell_size + font_size / 3, number
            )

    def mousePressEvent(self, event):
        x = round((event.x() - self.margin_left) / self.cell_size)
        y = round((event.y() - self.margin_top) / self.cell_size)
        if 0 <= x < self.board_size and 0 <= y < self.board_size:
            move = self.main_window.game_logic.current_node.rowcol_to_bw(y, x, self.board_size)
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

    def process_policy_data(self, policy):
        game_logic = self.main_window.game_logic
        board_size = game_logic.board_size
        heatmap_mean_prob = np.zeros((board_size, board_size))
        heatmap_mean_rank = np.zeros((board_size, board_size))
    
        if isinstance(policy, tuple):
            policies = policy
            policy_top_moves = {p: game_logic.get_top_moves(p, **self.main_window.config_panel.get_sampling_settings()) for p in policies}
            n_ready = sum(1 for p in policies if policy_top_moves[p])
            for ip, policy in enumerate(policies):
                top_moves, _ = policy_top_moves[policy]
                for move, prob in top_moves:
                    if move == "pass":
                        continue
                    y, x = game_logic.current_node.bw_to_rowcol(move, board_size)
                    heatmap_mean_prob[y][x] += prob/n_ready
                    heatmap_mean_rank[y][x] += ip * prob/n_ready
        
            heatmap_mean_rank = heatmap_mean_rank / heatmap_mean_prob.clip(min=1e-10)
        else:
            top_moves, _ = game_logic.get_top_moves(policy, **self.main_window.config_panel.get_sampling_settings())
            for move, prob in top_moves:
                if move.lower() == "pass":
                    continue
                y, x = game_logic.current_node.bw_to_rowcol(move, board_size)
                heatmap_mean_prob[y][x] += prob
            heatmap_mean_rank = np.ones((board_size, board_size))    
    
        return heatmap_mean_prob, heatmap_mean_rank
    
    def draw_heatmap(self, painter, policy, show_text, sampling_settings):
        heatmap_mean_prob, heatmap_mean_rank = self.process_policy_data(policy)
        self.draw_heatmap_points(painter, heatmap_mean_prob, heatmap_mean_rank, show_text)

    def draw_heatmap_points(self, painter, heatmap_mean_prob, heatmap_mean_rank, show_text):
        for y in range(self.board_size):
            for x in range(self.board_size):
                if heatmap_mean_prob[y][x] > 0:
                    mean_rank = heatmap_mean_rank[y][x]
                    color = self.get_heatmap_color(mean_rank)
                    self.draw_heatmap_point_custom(painter, x, y, heatmap_mean_prob[y][x], mean_rank, color, show_text)

    def get_heatmap_color(self, mean_rank):
        if mean_rank <= 0:
            return QColor(57, 255, 20) # Light Green
        elif mean_rank < 1: # Interpolate between Light Green and Dark Green
            ratio = mean_rank / 1
            return self.interpolate_color(QColor(57, 255, 20), QColor(0, 100, 0), ratio)
        else:            # Interpolate between Dark Green and Dark Blue
            ratio = min(1,(mean_rank - 1) / 1)
            return self.interpolate_color(QColor(0, 100, 0), QColor(0, 0, 139), ratio)


    def interpolate_color(self, color1, color2, ratio):
        r = color1.red() + (color2.red() - color1.red()) * ratio
        g = color1.green() + (color2.green() - color1.green()) * ratio
        b = color1.blue() + (color2.blue() - color1.blue()) * ratio
        return QColor(int(r), int(g), int(b))

    def draw_heatmap_point_custom(self, painter, x, y, total_prob, mean_rank, color, show_text):
        y = self.board_size - y - 1
        center = QPointF(self.margin_left + x * self.cell_size, self.margin_top + y * self.cell_size)
    
        alpha = int(255 * min(total_prob, 1) ** 0.5)
    
        gradient = QRadialGradient(center, self.stone_size / 2)
        gradient.setColorAt(0, color)
        gradient.setColorAt(1, QColor(color.red(), color.green(), color.blue(), int(alpha * 0.3)))
    
        painter.setBrush(QBrush(gradient))
        painter.setPen(Qt.NoPen)
        painter.drawEllipse(center, self.stone_size / 2, self.stone_size / 2)
    
        if show_text:
            font = QFont("Arial", int(self.cell_size / 3.5))
            font.setBold(True)
            painter.setFont(font)
    
            text = f"{total_prob:.1%}" if total_prob < 100 else f"{total_prob:.0%}"
            logger.debug(f"draw_heatmap_point_custom with {text=} for {x=}, {y=} {total_prob=} {mean_rank=} {alpha=}")
            text_rect = painter.fontMetrics().boundingRect(text)
    
            text_x = center.x() - text_rect.width() / 2
            text_y = center.y() + text_rect.height() / 3
            painter.setPen(Qt.white)
            painter.drawText(text_x, text_y, text)

