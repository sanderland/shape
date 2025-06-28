from functools import cache

from PySide6.QtCore import Qt
from PySide6.QtGui import QKeySequence, QShortcut
from PySide6.QtWidgets import (
    QButtonGroup,
    QCheckBox,
    QComboBox,
    QGridLayout,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QProgressBar,
    QPushButton,
    QSizePolicy,
)

from shape.ui.ui_utils import SettingsTab
from shape.utils import setup_logging

logger = setup_logging()

RANK_RANGE = (-20, 9)


@cache
def get_rank_from_id(id: int) -> str:
    if id < 0:
        return f"{-id}k"
    return f"{id + 1}d"


def get_human_profile_from_id(id: int, preaz: bool = False) -> str | None:
    if id >= RANK_RANGE[1] + 10:
        return None  # AI
    if id >= RANK_RANGE[1]:
        return "proyear_2023"
    return f"{'preaz_' if preaz else 'rank_'}{get_rank_from_id(id)}"


class ControlPanel(SettingsTab):
    def create_widgets(self):
        self.setSpacing(5)
        self.addWidget(self.create_game_control_box())
        self.addWidget(self.create_player_settings_group())
        self.addWidget(self.create_collapsible_info_panel())
        self.addStretch(1)

    def create_game_control_box(self):
        group = QGroupBox("Game Control")
        layout = QGridLayout()
        layout.setVerticalSpacing(5)
        layout.setHorizontalSpacing(5)

        layout.addWidget(QLabel("Play as:"), 0, 0)
        self.player_color = QButtonGroup(self)
        for i, color in enumerate(["Black", "White"]):
            button = QPushButton(color)
            button.setCheckable(True)
            self.player_color.addButton(button)
            layout.addWidget(button, 0, i + 1)
        self.player_color.buttons()[0].setChecked(True)

        self.auto_play_checkbox = QCheckBox("Auto-play", checked=True)
        self.ai_move_button = QPushButton("Force Move (Ctrl+Enter)")
        self.ai_move_button.setShortcut("Ctrl+Enter")
        layout.addWidget(QLabel("Opponent:"), 1, 0)
        layout.addWidget(self.ai_move_button, 1, 1)
        layout.addWidget(self.auto_play_checkbox, 1, 2)

        group.setLayout(layout)
        return group

    def create_player_settings_group(self):
        group = QGroupBox("Player Settings")
        layout = QGridLayout()
        layout.setVerticalSpacing(5)
        layout.setHorizontalSpacing(5)

        # Rank settings
        self.rank_dropdowns = {}
        layout.addWidget(QLabel("Current Rank:"), 0, 0)
        self.rank_dropdowns["current"] = QComboBox()
        self.populate_rank_combo(self.rank_dropdowns["current"], "3k")
        layout.addWidget(self.rank_dropdowns["current"], 0, 1)

        # Target Rank
        layout.addWidget(QLabel("Target Rank:"), 0, 2)
        self.rank_dropdowns["target"] = QComboBox()
        self.populate_rank_combo(self.rank_dropdowns["target"], "2d")
        layout.addWidget(self.rank_dropdowns["target"], 0, 3)

        # Opponent selection
        layout.addWidget(QLabel("Opponent:"), 1, 0)
        self.opponent_type_combo = QComboBox()
        self.opponent_type_combo.addItems(["Rank", "Pre-AZ", "Pro"])

        layout.addWidget(self.opponent_type_combo, 1, 1)

        self.opponent_pro_combo = QComboBox()
        self.populate_pro_combo(self.opponent_pro_combo)
        layout.addWidget(self.opponent_pro_combo, 1, 2, 1, 2)

        self.opponent_rank_combo = QComboBox()
        self.populate_rank_combo(self.opponent_rank_combo, "1k")
        layout.addWidget(self.opponent_rank_combo, 1, 2, 1, 2)

        self.opponent_rank_preaz_combo = QComboBox()
        self.populate_rank_combo(self.opponent_rank_preaz_combo, "1k")
        layout.addWidget(self.opponent_rank_preaz_combo, 1, 2, 1, 2)

        # Heatmap settings
        layout.addWidget(QLabel("Heatmap:"), 3, 0)
        heatmap_layout = QHBoxLayout()
        heatmap_layout.setSpacing(2)  # Reduce spacing between heatmap buttons

        self.heatmap_buttons = {}
        heatmap_colors = {
            "Current": self.main_window.board_view.PLAYER_POLICY_COLOR,
            "Target": self.main_window.board_view.TARGET_POLICY_COLOR,
            "AI": self.main_window.board_view.AI_POLICY_COLOR,
            "Opponent": self.main_window.board_view.OPPONENT_POLICY_COLOR,
        }
        for text, shortcut in [("Current", "Ctrl+1"), ("Target", "Ctrl+2"), ("AI", "Ctrl+3"), ("Opponent", "Ctrl+9")]:
            button = QPushButton(f"{text} ({shortcut})")
            button.setCheckable(True)
            button.setShortcut(shortcut)
            color = heatmap_colors[text]
            button.setStyleSheet(
                f"""
                QPushButton:checked {{
                    background-color: {color.name()};
                    border: 2px solid black;
                    color: white;
                }}
            """
            )
            self.heatmap_buttons[text.lower()] = button
            heatmap_layout.addWidget(button)

        layout.addLayout(heatmap_layout, 3, 1, 1, 3)

        group.setLayout(layout)
        return group

    def create_collapsible_info_panel(self):
        self.info_group = QGroupBox("Info (Ctrl+0)")
        self.info_group.setCheckable(True)
        self.info_group.setChecked(False)
        shortcut = QShortcut(QKeySequence("Ctrl+0"), self.main_window)
        shortcut.activated.connect(lambda: self.info_group.setChecked(not self.info_group.isChecked()))
        layout = QGridLayout()

        self.last_move_label = QLabel("Last move: N/A")
        self.current_policy_widget = ProbabilityWidget()
        self.target_policy_widget = ProbabilityWidget()
        self.ai_policy_widget = ProbabilityWidget()
        self.bayesian_prob_widget = ProbabilityWidget()

        layout.addWidget(QLabel("Last move:"), 0, 0)
        layout.addWidget(self.last_move_label, 0, 1)
        layout.addWidget(QLabel("Current rank policy:"), 1, 0)
        layout.addWidget(self.current_policy_widget, 1, 1)
        layout.addWidget(QLabel("Target rank policy:"), 2, 0)
        layout.addWidget(self.target_policy_widget, 2, 1)
        layout.addWidget(QLabel("AI policy:"), 3, 0)
        layout.addWidget(self.ai_policy_widget, 3, 1)
        layout.addWidget(QLabel("P(target | move):"), 4, 0)
        layout.addWidget(self.bayesian_prob_widget, 4, 1)

        self.halted_reason_label = QLabel("")
        self.halted_reason_label.setWordWrap(True)
        self.halted_reason_label.setAlignment(Qt.AlignLeft | Qt.AlignTop)
        self.halted_reason_label.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Minimum)
        layout.addWidget(self.halted_reason_label, 5, 0, 1, 2)
        self.halted_reason_label.setWordWrap(True)
        self.halted_reason_label.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Minimum)
        self.info_group.setLayout(layout)
        return self.info_group

    def populate_rank_combo(self, combo, default_rank: str):
        for id in range(*RANK_RANGE):
            combo.addItem(get_rank_from_id(id), id)
        combo.setCurrentText(default_rank)

    def populate_pro_combo(self, combo):
        pro_years = [f"proyear_{year}" for year in range(1803, 2024, 5)]
        combo.addItems(pro_years)
        combo.setCurrentText("proyear_1985")

    def connect_signals(self):
        self.player_color.buttonClicked.connect(self.on_settings_changed)
        for button in self.heatmap_buttons.values():
            button.toggled.connect(self.on_settings_changed)
        self.auto_play_checkbox.stateChanged.connect(self.on_settings_changed)
        for spinbox in self.rank_dropdowns.values():
            spinbox.currentIndexChanged.connect(self.on_settings_changed)
        self.info_group.toggled.connect(self.on_settings_changed)
        self.opponent_type_combo.currentIndexChanged.connect(self.on_opponent_type_changed)

    def on_opponent_type_changed(self):
        opponent_type = self.opponent_type_combo.currentText()
        self.opponent_pro_combo.setVisible(opponent_type == "Pro")
        self.opponent_rank_combo.setVisible(opponent_type == "Rank")
        self.opponent_rank_preaz_combo.setVisible(opponent_type == "Pre-AZ")

    def get_human_profiles(self):
        opponent_type = self.opponent_type_combo.currentText()

        if opponent_type == "Pro":
            opponent_profile = self.opponent_pro_combo.currentText()
        elif opponent_type == "Rank":
            opponent_profile = get_human_profile_from_id(self.opponent_rank_combo.currentData())
        else:  # Rank (pre-AZ)
            opponent_profile = get_human_profile_from_id(self.opponent_rank_preaz_combo.currentData(), preaz=True)

        return {
            "player": get_human_profile_from_id(self.rank_dropdowns["current"].currentData()),
            "opponent": opponent_profile,
            "target": get_human_profile_from_id(self.rank_dropdowns["target"].currentData()),
        }

    def get_player_color(self):
        return self.player_color.checkedButton().text()[0]

    def is_auto_play_enabled(self):
        return self.auto_play_checkbox.isChecked()

    def get_move_stats(self, node):
        if not node.move:  # root
            return None
        human_profiles = self.get_human_profiles()
        currentlv_analysis = node.get_analysis(human_profiles["player"], parent=True)
        target_analysis = node.get_analysis(human_profiles["target"], parent=True)
        ai_analysis = node.get_analysis(None, parent=True)
        if currentlv_analysis and target_analysis and ai_analysis:
            player_prob, player_relative_prob = currentlv_analysis.human_policy.at(node.move)
            target_prob, target_relative_prob = target_analysis.human_policy.at(node.move)
            ai_prob, ai_relative_prob = ai_analysis.ai_policy.at(node.move)
            return {
                "player_prob": player_prob,
                "target_prob": target_prob,
                "ai_prob": ai_prob,
                "player_relative_prob": player_relative_prob,
                "target_relative_prob": target_relative_prob,
                "ai_relative_prob": ai_relative_prob,
                "move_like_target": target_prob / max(player_prob + target_prob, 1e-10),
                "mistake_size": node.mistake_size(),
            }
        return None

    def get_heatmap_settings(self):
        human_profiles = self.get_human_profiles()
        policies = [
            (human_profiles["player"], self.heatmap_buttons["current"].isChecked()),
            (human_profiles["target"], self.heatmap_buttons["target"].isChecked()),
            (None, self.heatmap_buttons["ai"].isChecked()),
        ]
        if self.heatmap_buttons["opponent"].isChecked():
            policies = [("", False)] * 3 + [(human_profiles["opponent"], True)]
        return {
            "policy": policies,
            "enabled": any(policy[1] for policy in policies),
        }

    def update_ui(self):
        if not self.heatmap_buttons["opponent"].isChecked():
            self.heatmap_buttons["opponent"].setFixedSize(0, 0)
        else:
            self.heatmap_buttons["opponent"].setFixedSize(self.heatmap_buttons["opponent"].sizeHint())
        game_logic = self.main_window.game_logic
        player_color = self.get_player_color()

        node = game_logic.current_node if game_logic.player == player_color else game_logic.current_node.parent

        if node and (last_player_move := node.move):
            self.last_move_label.setText(f"Last move: {last_player_move.gtp()}")
        else:
            self.last_move_label.setText("Last move: N/A")

        if node and node.autoplay_halted_reason:
            self.halted_reason_label.setText(f"Critical mistake: {node.autoplay_halted_reason}")
        else:
            self.halted_reason_label.setText("")

        if self.info_group.isChecked() and node and (move_stats := self.get_move_stats(node)):
            self.current_policy_widget.update_probability(move_stats["player_prob"], move_stats["player_relative_prob"])
            self.target_policy_widget.update_probability(move_stats["target_prob"], move_stats["target_relative_prob"])
            self.ai_policy_widget.update_probability(move_stats["ai_prob"], move_stats["ai_relative_prob"])
            self.bayesian_prob_widget.update_probability(move_stats["move_like_target"])
        else:
            self.current_policy_widget.set_na()
            self.target_policy_widget.set_na()
            self.ai_policy_widget.set_na()
            self.bayesian_prob_widget.set_na()


class ProbabilityWidget(QProgressBar):
    def __init__(self, probability: float = 0):
        super().__init__()
        self.setValue(probability * 100)
        self.setTextVisible(True)
        self.setStyleSheet(
            "QProgressBar::chunk { background-color: green; }"
            "QProgressBar { background-color: #aaa; border: 1px solid #cccccc; font-size: 14px; font-weight: bold; color: #eee; text-align: center; }"
        )

    def update_probability(self, label_probability: float, fill_percentage: float = None):
        fill_percentage = fill_percentage or label_probability
        self.setFormat(f"{label_probability:.2%}")
        self.setValue(fill_percentage * 100)

    def set_na(self):
        self.setValue(0)
        self.setFormat("N/A")
