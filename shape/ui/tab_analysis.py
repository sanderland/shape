import pyqtgraph as pg
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

        self.graph_widget = pg.PlotWidget()
        self.graph_widget.setBackground("w")
        self.graph_widget.setLabel("left", "Score")
        self.graph_widget.showGrid(x=True, y=True, alpha=0.3)
        self.addWidget(self.graph_widget)
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
        table.horizontalHeader().setSectionResizeMode(QHeaderView.Stretch)
        table.setEditTriggers(QTableWidget.NoEditTriggers)
        table.setFocusPolicy(Qt.NoFocus)
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
        moves, filtered_values = zip(*scores, strict=False)
        self.graph_widget.plot(moves, filtered_values, pen=pg.mkPen(color="b", width=2), clear=True)
        self.graph_widget.setYRange(min(filtered_values) - 0.1, max(filtered_values) + 0.1)
        self.graph_widget.setXRange(0, max(1, len(moves) - 1))
