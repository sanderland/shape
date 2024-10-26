import pyqtgraph as pg
from PySide6.QtWidgets import QSizePolicy, QVBoxLayout, QWidget


class ScoreGraph(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.layout = QVBoxLayout(self)
        self.graph_widget = pg.PlotWidget()
        self.layout.addWidget(self.graph_widget)

        self.graph_widget.setSizePolicy(
            QSizePolicy.Expanding, QSizePolicy.Expanding
        )  # Ensure the widget expands to fill the parent
        self.setMinimumHeight(200)  # Set a minimum height for better visibility
        self.graph_widget.setBackground("w")
        self.graph_widget.setLabel("left", "Score")
        self.graph_widget.setLabel("bottom", "Move")

        self.data_lines = {}

        self.setStyleSheet("background-color: #e0e0e0;")  # Updated background color for better contrast

        # Additional styling for the graph
        # self.graph_widget.setTitle("Score Analysis", color="black", size="14pt")
        self.graph_widget.showGrid(x=True, y=True, alpha=0.3)  # Added grid for better readability

    def update_graph(self, scores):
        colors = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0), (255, 0, 255), (0, 255, 255)]
        all_filtered_values = []
        for i, (key, values) in enumerate(scores.items()):
            moves = []
            filtered_values = []
            for move, value in enumerate(values):
                if value is not None:
                    moves.append(move)
                    filtered_values.append(value)

            if key not in self.data_lines:
                color = colors[i % len(colors)]
                self.data_lines[key] = self.graph_widget.plot([], [], pen=pg.mkPen(color=color, width=2), name=key)

            self.data_lines[key].setData(moves, filtered_values)
            all_filtered_values.extend(filtered_values)

        # Set the range for the axes based on the data
        if all_filtered_values:
            self.graph_widget.setYRange(min(all_filtered_values) - 0.1, max(all_filtered_values) + 0.1)
            self.graph_widget.setXRange(0, len(moves) - 1)


#        else:
#            self.graph_widget.setYRange(-1, 1)
#            self.graph_widget.setXRange(0, 10)

# self.graph_widget.addLegend()
