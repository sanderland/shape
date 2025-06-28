from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import (
    QDoubleSpinBox,
    QFormLayout,
    QGroupBox,
    QLabel,
    QSpinBox,
    QVBoxLayout,
    QWidget,
)

# Stylesheets
MAIN_STYLESHEET = """
QWidget {
    font-size: 11px;
}
QGroupBox {
    font-weight: bold;
    border: 1px solid #cccccc;
    border-radius: 6px;
    margin-top: 6px;
    padding-top: 6px;
}
QGroupBox::title {
    subcontrol-origin: margin;
    left: 7px;
    padding: 0px 5px 0px 5px;
}
QPushButton {
    background-color: #f0f0f0;
    border: 1px solid #cccccc;
    border-radius: 4px;
    padding: 3px;
    min-width: 30px;
}
QPushButton:hover {
    background-color: #e0e0e0;
}
QPushButton:checked {
    background-color: #c0c0c0;
    border: 2px solid #808080;
}
QComboBox, QSpinBox {
    border: 1px solid #cccccc;
    border-radius: 4px;
    padding: 1px;
    min-width: 30px;
}
QLabel {
    padding-right: 3px;
}
QTableWidget {
    border: 1px solid #cccccc;
    border-radius: 5px;
}
"""


# Helper functions
def create_spin_box(min_value, max_value, default_value):
    spin_box = QSpinBox()
    spin_box.setRange(min_value, max_value)
    spin_box.setValue(default_value)
    return spin_box


def create_double_spin_box(min_value, max_value, default_value, step):
    spin_box = QDoubleSpinBox()
    spin_box.setRange(min_value, max_value)
    spin_box.setSingleStep(step)
    spin_box.setValue(default_value)
    return spin_box


def create_config_section(title: str, widgets: dict[str, QWidget], note: str = None):
    sample_box = QGroupBox(title)
    sampling_form_layout = QFormLayout()
    sampling_form_layout.setLabelAlignment(Qt.AlignRight)
    sampling_form_layout.setFieldGrowthPolicy(QFormLayout.AllNonFixedFieldsGrow)
    if note:
        sampling_form_layout.addRow(QLabel(note, wordWrap=True))
    for k, widget in widgets.items():
        sampling_form_layout.addRow(k, widget)
    sample_box.setLayout(sampling_form_layout)
    return sample_box


def create_label_info_section(labels: dict[str, str]):
    holding_widget = QWidget()
    info_form_layout = QFormLayout()
    info_form_layout.setLabelAlignment(Qt.AlignLeft)
    widgets = {k: QLabel() for k, v in labels.items()}
    for k, v in labels.items():
        info_form_layout.addRow(v, widgets[k])
    holding_widget.setLayout(info_form_layout)
    return holding_widget, widgets


class SettingsTab(QVBoxLayout):
    settings_updated = Signal()

    def __init__(self, main_window):
        super().__init__()
        self.main_window = main_window
        self.setSpacing(10)
        self.setContentsMargins(10, 10, 10, 10)
        self.create_widgets()
        self.connect_signals()

    def create_widgets(self):
        pass

    def connect_signals(self):
        pass

    def on_settings_changed(self):
        self.settings_updated.emit()

    def update_ui(self):
        pass
