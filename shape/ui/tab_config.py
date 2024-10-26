from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import QFormLayout, QGroupBox, QHBoxLayout, QLabel, QVBoxLayout

from shape.ui.ui_utils import SettingsTab, create_double_spin_box, create_spin_box


class ConfigPanel(SettingsTab):
    settings_changed = Signal()

    def create_widgets(self):
        sample_box = QGroupBox("Sampling Settings")
        form_layout = QFormLayout()
        form_layout.setLabelAlignment(Qt.AlignRight)
        form_layout.setFieldGrowthPolicy(QFormLayout.AllNonFixedFieldsGrow)

        self.top_k = create_spin_box(1, 100, 50)
        self.top_p = create_double_spin_box(0.1, 1.0, 1.0, 0.05)
        self.min_p = create_double_spin_box(0.0, 1.0, 0.05, 0.01)

        form_layout.addRow("Top K:", self.top_k)
        form_layout.addRow("Top P:", self.top_p)
        form_layout.addRow("Min P:", self.min_p)

        sample_box.setLayout(form_layout)
        self.addWidget(sample_box)

        ai_strength_box = QGroupBox("Analysis Settings")
        ai_strength_layout = QHBoxLayout()
        ai_strength_layout.addWidget(QLabel("Visits:"))
        self.visits = create_spin_box(8, 1024, 24)
        ai_strength_layout.addWidget(self.visits)
        ai_strength_box.setLayout(ai_strength_layout)
        self.addWidget(ai_strength_box)

        self.addStretch(1)

    def connect_signals(self):
        for widget in [self.top_k, self.top_p, self.min_p, self.visits]:
            widget.valueChanged.connect(self.on_settings_changed)

    def get_ai_strength(self):
        return self.visits.value()

    def get_sampling_settings(self):
        return {
            "top_k": self.top_k.value(),
            "top_p": self.top_p.value(),
            "min_p": self.min_p.value(),
        }
