from functools import cache

from PySide6.QtCore import Qt, Signal, Slot
from PySide6.QtGui import QFont
from PySide6.QtWidgets import (QButtonGroup, QCheckBox, QComboBox, QGridLayout, QGroupBox, QHBoxLayout, QLabel,
                               QProgressBar, QPushButton, QSpinBox, QVBoxLayout, QWidget)

from shape.game_logic import GameLogic
from shape.ui.ui_utils import SettingsTab, create_spin_box
from shape.utils import setup_logging

logger = setup_logging()

RANK_RANGE = (-20, 9)


@cache
def get_rank_from_id(id: int) -> str:
    if id < 0:
        return f"{-id}k"
    return f"{id+1}d"


def get_human_profile_from_id(id: int) -> str:
    if id >= RANK_RANGE[1]:
        return "proyear_2023"
    return "rank_" + get_rank_from_id(id)


class ControlPanel(SettingsTab):
    DEFAULT_RANKS = {"current": -5, "opponent_diff": 3, "target_diff": 6}

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

        self.ai_move_button = QPushButton("AI Move (Ctrl+Enter)")
        self.ai_move_button.setShortcut("Ctrl+Enter")
        self.auto_play_checkbox = QCheckBox("Auto-play", checked=True)

        layout.addWidget(self.ai_move_button, 0, 0, 1, 2)
        layout.addWidget(self.auto_play_checkbox, 0, 2)

        layout.addWidget(QLabel("Play as:"), 1, 0, 1, 2)
        self.player_color = QButtonGroup(self)
        for i, color in enumerate(["Black", "White"]):
            button = QPushButton(color)
            button.setCheckable(True)
            self.player_color.addButton(button)
            layout.addWidget(button, 1, i + 1)
        self.player_color.buttons()[0].setChecked(True)

        layout.addWidget(QLabel("Halt on:"), 2, 0)
        layout.addWidget(QLabel("Mistake size >"), 3, 0)
        self.mistake_size_spinbox = create_spin_box(0, 100, 1)
        layout.addWidget(self.mistake_size_spinbox, 3, 1)
        layout.addWidget(QLabel("pts"), 3, 2)

        layout.addWidget(QLabel("Target rank likeliness <"), 4, 0)
        self.target_rank_spinbox = create_spin_box(0, 100, 20)
        layout.addWidget(self.target_rank_spinbox, 4, 1)
        layout.addWidget(QLabel("%"), 4, 2)

        layout.addWidget(QLabel("Or max prob. <"), 5, 0)
        self.max_probability_spinbox = create_spin_box(0, 5, 1)
        layout.addWidget(self.max_probability_spinbox, 5, 1)
        layout.addWidget(QLabel("%"), 5, 2)

        group.setLayout(layout)
        return group

    def create_player_settings_group(self):
        group = QGroupBox("Player Settings")
        layout = QGridLayout()
        layout.setVerticalSpacing(5)
        layout.setHorizontalSpacing(5)

        # Rank settings
        self.rank_spinboxes = {}
        layout.addWidget(QLabel("Current Rank:"), 0, 0)
        self.rank_combo = QComboBox()
        self.populate_rank_combo(self.rank_combo)
        layout.addWidget(self.rank_combo, 0, 1, 1, 3)

        self.rank_labels = {}
        for i, rank_type in enumerate(["opponent", "target"]):
            layout.addWidget(QLabel(f"{rank_type.capitalize()} Rank:"), i + 1, 0)
            layout.addWidget(QLabel("Current +"), i + 1, 1)
            self.rank_spinboxes[rank_type] = create_spin_box(0, 99, self.DEFAULT_RANKS[f"{rank_type}_diff"])
            layout.addWidget(self.rank_spinboxes[rank_type], i + 1, 2)
            self.rank_labels[rank_type] = QLabel("stones")
            layout.addWidget(self.rank_labels[rank_type], i + 1, 3)

        # Heatmap settings
        layout.addWidget(QLabel("Heatmap:"), 3, 0)
        heatmap_layout = QGridLayout()
        heatmap_layout.setSpacing(2)  # Reduce spacing between heatmap buttons
        self.policy_button_group = QButtonGroup(self)
        self.policy_button_group.setExclusive(True)

        policy_buttons = {
            "Player": (0, 0, "Ctrl+1"),
            "Target": (0, 1, "Ctrl+2"),
            "Opponent": (1, 0, "Ctrl+3"),
            "AI": (1, 1, "Ctrl+4"),
            "Player-Target": (2, 0, "Ctrl+5"),
            "Target-AI": (2, 1, "Ctrl+6"),
            "Hybrid": (3, 0, "Ctrl+7"),
            "Off": (3, 1, "Ctrl+8"),
        }

        for text, (row, col, *shortcut) in policy_buttons.items():
            button = QPushButton(f"{text} ({shortcut[0]})")
            button.setCheckable(True)
            if shortcut:
                button.setShortcut(shortcut[0])
            self.policy_button_group.addButton(button)
            button.setChecked(text == "Off")
            heatmap_layout.addWidget(button, row, col)

        self.heatmap_text_toggle = QPushButton("+text")
        self.heatmap_text_toggle.setCheckable(True)
        self.heatmap_text_toggle.setShortcut("Ctrl+T")
        self.heatmap_text_toggle.setChecked(True)
        heatmap_layout.addWidget(self.heatmap_text_toggle, 4, 0, 1, 2)  # Span two columns

        layout.addLayout(heatmap_layout, 3, 1, 1, 3)

        group.setLayout(layout)
        return group

    def create_collapsible_info_panel(self):
        self.info_group = QGroupBox("Info")
        self.info_group.setCheckable(True)
        self.info_group.setChecked(False)
        layout = QGridLayout()

        self.last_move_label = QLabel("Last move: N/A")
        self.player_policy_widget = ProbabilityWidget()
        self.target_policy_widget = ProbabilityWidget()
        self.ai_policy_widget = ProbabilityWidget()
        self.bayesian_prob_widget = ProbabilityWidget()

        layout.addWidget(QLabel("Last move:"), 0, 0)  # Label for last move
        layout.addWidget(self.last_move_label, 0, 1)  # Widget for last move
        layout.addWidget(QLabel("Player policy:"), 1, 0)  # Label for player policy
        layout.addWidget(self.player_policy_widget, 1, 1)  # Widget for player policy
        layout.addWidget(QLabel("Target policy:"), 2, 0)  # Label for target policy
        layout.addWidget(self.target_policy_widget, 2, 1)  # Widget for target policy
        layout.addWidget(QLabel("AI policy:"), 3, 0)  # Label for AI policy
        layout.addWidget(self.ai_policy_widget, 3, 1)  # Widget for AI policy
        layout.addWidget(QLabel("P(target | move):"), 4, 0)  # Label for Bayesian probability
        layout.addWidget(self.bayesian_prob_widget, 4, 1)  # Widget for Bayesian probability

        self.info_group.setLayout(layout)
        return self.info_group

    def create_probability_widget(self, label_text, probability):
        widget = QHBoxLayout()
        label = QLabel(label_text)
        progress_bar = QProgressBar()
        progress_bar.setValue(probability * 100)  # Convert to percentage
        progress_bar.setTextVisible(False)
        progress_bar.setStyleSheet(
            "QProgressBar::chunk { background-color: green; }" "QProgressBar { background-color: lightgray; }"
        )
        widget.addWidget(label)
        widget.addWidget(progress_bar)
        return widget

    def populate_rank_combo(self, combo):
        for id in range(*RANK_RANGE):
            combo.addItem(get_rank_from_id(id), id)
        combo.setCurrentIndex(combo.findData(self.DEFAULT_RANKS["current"]))

    def connect_signals(self):
        self.rank_combo.currentIndexChanged.connect(self.on_settings_changed)
        self.player_color.buttonClicked.connect(self.on_settings_changed)
        self.policy_button_group.buttonToggled.connect(self.on_settings_changed)
        self.auto_play_checkbox.stateChanged.connect(self.on_settings_changed)
        self.heatmap_text_toggle.clicked.connect(self.on_settings_changed)
        for spinbox in self.rank_spinboxes.values():
            spinbox.valueChanged.connect(self.on_settings_changed)
        self.info_group.toggled.connect(self.on_settings_changed)

    def get_human_profiles(self):
        current_rank = self.rank_combo.currentData()
        return {
            "player": get_human_profile_from_id(current_rank),
            "opponent": get_human_profile_from_id(current_rank + self.rank_spinboxes["opponent"].value()),
            "target": get_human_profile_from_id(current_rank + self.rank_spinboxes["target"].value()),
        }

    def get_player_color(self):
        return self.player_color.checkedButton().text()[0]

    def is_auto_play_enabled(self):
        return self.auto_play_checkbox.isChecked()

    def get_move_stats(self, node):
        if not node.move:  # root
            return None
        human_profiles = self.get_human_profiles()
        move = node.move[1]
        player_policy = node.get_analysis(human_profiles["player"], parent=True)
        target_policy = node.get_analysis(human_profiles["target"], parent=True)
        ai_policy = node.get_analysis(None, parent=True)
        if player_policy and target_policy and ai_policy:
            player_prob, player_relative_prob = player_policy.move_probability(move)
            target_prob, target_relative_prob = target_policy.move_probability(move)
            ai_prob, ai_relative_prob = ai_policy.move_probability(move)
            return dict(
                player_prob=player_prob,
                target_prob=target_prob,
                ai_prob=ai_prob,
                player_relative_prob=player_relative_prob,
                target_relative_prob=target_relative_prob,
                ai_relative_prob=ai_relative_prob,
                move_like_target=target_prob / max(player_prob + target_prob, 1e-10),
                mistake_size=node.calculate_mistake_size(),
            )
        return None

    def should_halt_on_mistake(self, node) -> bool | None:
        move_stats = self.get_move_stats(node)
        logger.debug(f"Getting move stats for {node.move} move_stats: {move_stats}")
        if move_stats:
            max_prob = max(move_stats[f"{k}_prob"] for k in ["player", "target", "ai"])
            return (move_stats["mistake_size"] > self.mistake_size_spinbox.value()) and (
                move_stats["move_like_target"] < self.target_rank_spinbox.value() / 100
                or max_prob < self.max_probability_spinbox.value() / 100
            )
        return None

    def get_heatmap_settings(self):
        human_profiles = self.get_human_profiles()
        policy_option = self.policy_button_group.checkedButton().text().lower()
        policy_option = policy_option.split(" ")[0]
        policy = None
    
        if policy_option in ["player", "opponent", "target"]:
            policy = human_profiles[policy_option]
        elif policy_option == "ai":
            policy = None
        elif policy_option == "player-target":
            policy = (human_profiles["player"], human_profiles["target"])
        elif policy_option == "target-ai":
            policy = ('missing', human_profiles["target"], None)
        elif policy_option == "hybrid":
            policy = (human_profiles["player"], human_profiles["target"], None)
        else:
            policy = None
    
        return {"policy": policy, "enabled": policy_option != "off", "text": self.heatmap_text_toggle.isChecked()}

    def update_ui(self, main_window):
        current_rank = self.rank_combo.currentData()
        for rank_type in ["opponent", "target"]:
            resulting_rank = current_rank + self.rank_spinboxes[rank_type].value()
            resulting_policy = get_human_profile_from_id(resulting_rank)
            self.rank_labels[rank_type].setText(f"stones → {resulting_policy}")
        self.update_info_panel(main_window.game_logic)

    def update_info_panel(self, game_logic: GameLogic):
        player_color = self.get_player_color()

        node = (
            game_logic.current_node
            if game_logic.current_player_color() == player_color
            else game_logic.current_node.parent
        )

        if node and node.move and (last_player_move := node.move[1]):
            self.last_move_label.setText(f"Last move: {last_player_move}")
        else:
            self.last_move_label.setText("Last move: N/A")

        if self.info_group.isChecked() and node and (move_stats := self.get_move_stats(node)):
            self.player_policy_widget.update_probability(move_stats["player_prob"], move_stats["player_relative_prob"])
            self.target_policy_widget.update_probability(move_stats["target_prob"], move_stats["target_relative_prob"])
            self.ai_policy_widget.update_probability(move_stats["ai_prob"], move_stats["ai_relative_prob"])
            self.bayesian_prob_widget.update_probability(move_stats["move_like_target"])
        else:
            self.player_policy_widget.set_na()
            self.target_policy_widget.set_na()
            self.ai_policy_widget.set_na()
            self.bayesian_prob_widget.set_na()


class ProbabilityWidget(QProgressBar):
    def __init__(self, probability: float = 0):
        super().__init__()
        self.setValue(probability * 100)  # Convert to percentage
        self.setTextVisible(True)  # Show text on the bar
        self.setStyleSheet(
            "QProgressBar::chunk { background-color: green; }"
            "QProgressBar { background-color: #aaa; border: 1px solid #cccccc; font-size: 14px; font-weight: bold; color: #eee; text-align: center; }"
        )

    def update_probability(self, label_probability: float, fill_percentage: float = None):
        fill_percentage = fill_percentage or label_probability
        self.setFormat(f"{label_probability:.2%}")
        self.setValue(fill_percentage * 100)  # Convert to percentage

    def set_na(self):
        self.setValue(0)
        self.setFormat("N/A")


