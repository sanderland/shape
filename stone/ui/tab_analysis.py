import numpy as np
from PySide6.QtCore import Qt
from PySide6.QtGui import QColor, QFont, QPalette
from PySide6.QtWidgets import QFrame, QHeaderView, QLabel, QTableWidget, QTableWidgetItem, QVBoxLayout

from stone.game_logic import GameLogic
from stone.ui.tab_main_control import ControlPanel
from stone.ui.ui_utils import SettingsTab, create_double_spin_box, create_spin_box
from stone.utils import setup_logging

from .score_graph import ScoreGraph

logger = setup_logging()


class AnalysisPanel(SettingsTab):
    def create_widgets(self):
        # Create labels
        self.win_rate_label = self.create_label("Black Win Rate: N/A", is_title=True)
        self.score_label = self.create_label("Score: N/A", is_title=True)
        self.mistake_size_label = self.create_label("Mistake Size (Score Lead): N/A", is_title=True)
        self.top_moves_label = self.create_label("Top Moves", is_title=True)

        # Add labels to layout
        for label in [
            self.win_rate_label,
            self.score_label,
            self.mistake_size_label,
            self.top_moves_label,
        ]:
            self.addWidget(label)

        # Create and add top moves table
        self.top_moves_table = self.create_top_moves_table()
        self.addWidget(self.top_moves_table)

        # Create and add score graph
        self.score_graph = ScoreGraph()
        self.addWidget(self.score_graph)

        self.addStretch(1)

    def create_label(self, text, is_title=False):
        label = QLabel(text)
        font = QFont()
        if is_title:
            font.setPointSize(16)
            font.setBold(True)
            label.setStyleSheet("background-color: #e0e0e0;")
        else:
            font.setPointSize(14)
        label.setFont(font)
        label.setAlignment(Qt.AlignLeft | Qt.AlignVCenter)
        return label

    def create_top_moves_table(self):
        table = QTableWidget(5, 4)
        table.setHorizontalHeaderLabels(["Move", "Win Rate", "Score", "Visits"])
        table.horizontalHeader().setSectionResizeMode(QHeaderView.Stretch)
        table.setEditTriggers(QTableWidget.NoEditTriggers)
        table.setFocusPolicy(Qt.NoFocus)
        table.setMinimumHeight(200)  # Set a minimum height for the table
        return table

    def update_ui(self, main_window):
        game_logic = main_window.game_logic
        analysis = game_logic.current_node.get_analysis(None)
        if analysis:
            win_rate = analysis.win_rate() * 100
            self.win_rate_label.setText(f"Win Rate: B {win_rate:.1f}%")

            score = analysis.ai_score()
            self.score_label.setText(f"Score: {score:+.1f}")

            top_moves = analysis.top_moves()
            for row, move in enumerate(top_moves):
                self.top_moves_table.setItem(row, 0, QTableWidgetItem(move["move"]))
                self.top_moves_table.setItem(row, 1, QTableWidgetItem(f"{move['winrate']*100:.1f}%"))
                self.top_moves_table.setItem(row, 2, QTableWidgetItem(f"{move['scoreLead']:.1f}"))
                self.top_moves_table.setItem(row, 3, QTableWidgetItem(f"{move['visits']}"))

            self.score_graph.update_graph(game_logic.get_score_history())
        else:
            self.clear()

        mistake_size = game_logic.current_node.calculate_mistake_size()
        if mistake_size is not None:
            self.mistake_size_label.setText(f"Mistake Size (Score Lead): {mistake_size:.2f}")
        else:
            self.mistake_size_label.setText("Mistake Size (Score Lead): N/A")

    def clear(self):
        self.win_rate_label.setText("Black Win Rate: N/A")
        self.score_label.setText("Score: N/A")
        self.mistake_size_label.setText("Mistake Size (Score Lead): N/A")
        self.top_moves_table.clearContents()
        self.score_graph.update_graph({})  # Clear the graph
