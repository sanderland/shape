import os

# Set Qt API before importing matplotlib
os.environ["QT_API"] = "pyside6"

import matplotlib

matplotlib.use("Qt5Agg")
from matplotlib.backends.backend_qt5agg import FigureCanvasQTAgg as FigureCanvas
from matplotlib.figure import Figure
from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QHeaderView,
    QLabel,
    QPushButton,
    QTableWidget,
    QTableWidgetItem,
)

from shape.ui.ui_utils import SettingsTab, create_label_info_section
from shape.utils import setup_logging

logger = setup_logging()


class AnalysisPanel(SettingsTab):
    WARNING_TEXT = "SHAPE is not optimized for AI analysis, and this tab is provided mainly for debugging and a quick look at the score graph after a game."

    def create_widgets(self):
        info_box, self.info_widgets = create_label_info_section(
            {
                "win_rate": "Black Win Rate:",
                "score": "Score:",
                "mistake_size": "Mistake Size (Score Lead):",
                "top_moves": "Top Moves:",
                "total_visits": "Total Visits:",
            }
        )
        self.addWidget(info_box)

        self.top_moves_table = self.create_top_moves_table()
        self.addWidget(self.top_moves_table)

        # Create matplotlib figure and canvas
        self.figure = Figure(figsize=(8, 4))
        self.canvas = FigureCanvas(self.figure)
        self.axes = self.figure.add_subplot(111)
        self.axes.set_xlabel("Move Number")
        self.axes.set_ylabel("Score")
        self.axes.grid(True, alpha=0.3)
        self.figure.tight_layout()
        self.addWidget(self.canvas)
        self.addStretch(1)

        extra_visits_button = QPushButton("Deeper AI Analysis")
        extra_visits_button.clicked.connect(self.on_extra_visits)
        self.addWidget(extra_visits_button)
        self.addWidget(QLabel(self.WARNING_TEXT, wordWrap=True))

    def on_extra_visits(self):
        current_node = self.main_window.game_logic.current_node
        current_analysis = current_node.get_analysis(None)
        current_visits = current_analysis.visit_count() if current_analysis else 0
        new_visits = max(500, int(current_visits * 2))
        self.main_window.request_analysis(current_node, human_profile=None, force_visits=new_visits)
        self.main_window.update_status_bar(f"Requested {new_visits} total visits")

    def create_top_moves_table(self):
        table = QTableWidget(5, 4)
        table.setHorizontalHeaderLabels(["Move", "B Win Rate", "B Score", "Visits"])
        table.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.Stretch)
        table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        table.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        table.setMinimumHeight(300)
        return table

    def update_ui(self):
        game_logic = self.main_window.game_logic
        analysis = game_logic.current_node.get_analysis(None)
        if analysis:
            win_rate = analysis.win_rate() * 100
            self.info_widgets["win_rate"].setText(f"{win_rate:.1f}%")
            score = analysis.ai_score()
            self.info_widgets["score"].setText(f"{'B' if score >= 0 else 'W'}+{abs(score):.1f}")
            self.info_widgets["total_visits"].setText(f"{analysis.visit_count()}")

            top_moves = analysis.ai_moves()
            self.top_moves_table.setRowCount(len(top_moves))
            for row, move in enumerate(top_moves):
                self.top_moves_table.setItem(row, 0, QTableWidgetItem(move["move"]))
                self.top_moves_table.setItem(row, 1, QTableWidgetItem(f"{move['winrate'] * 100:.1f}%"))
                self.top_moves_table.setItem(row, 2, QTableWidgetItem(f"{move['scoreLead']:.1f}"))
                self.top_moves_table.setItem(row, 3, QTableWidgetItem(f"{move['visits']}"))

        else:
            self.clear()
        self.update_graph(game_logic.get_score_history() or [(0, 0)])

        mistake_size = game_logic.current_node.mistake_size()
        if mistake_size is not None:
            self.info_widgets["mistake_size"].setText(f"{mistake_size:.2f}")
        else:
            self.info_widgets["mistake_size"].setText("N/A")

    def clear(self):
        for widget in self.info_widgets.values():
            widget.setText("N/A")
        self.top_moves_table.clearContents()

    def update_graph(self, scores: list[tuple[int, float]]):
        if not scores:
            scores = [(0, 0.0)]

        moves, filtered_values = zip(*scores, strict=False)

        # Clear the plot and redraw
        self.axes.clear()
        self.axes.plot(moves, filtered_values, "b-o", linewidth=2, markersize=6)
        self.axes.set_xlabel("Move Number")
        self.axes.set_ylabel("Score")
        self.axes.grid(True, alpha=0.3)

        # Add dashed horizontal line at score=0
        self.axes.axhline(y=0, color="gray", linestyle="--", alpha=0.7)

        # Set x-axis from 0 to max move number (no padding)
        max_move = max(moves) if moves else 0
        self.axes.set_xlim(0, max(1, max_move))

        # Center y-axis on 0
        y_min, y_max = min(filtered_values), max(filtered_values)
        y_abs_max = max(abs(y_min), abs(y_max), 0.5)  # Minimum range of 1.0 total
        self.axes.set_ylim(-y_abs_max, y_abs_max)

        # Refresh the canvas
        self.canvas.draw()
