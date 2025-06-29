from PySide6.QtCore import Qt
from PySide6.QtWidgets import QFormLayout, QGroupBox, QHBoxLayout, QLabel, QVBoxLayout

from shape.ui.ui_utils import (
    SettingsTab,
    create_double_spin_box,
    create_spin_box,
)


class ConfigPanel(SettingsTab):
    def create_widgets(self):
        self.insertSpacing(0, 10)
        # --- Policy Sampling Group ---
        policy_group = QGroupBox("Policy Sampling")
        policy_layout = QFormLayout(policy_group)

        policy_explanation = QLabel(
            "Controls how the AI opponent samples moves to simulate a human player. This does not affect the main analysis engine."
        )
        policy_explanation.setWordWrap(True)
        policy_layout.addRow(policy_explanation)

        self.top_k = create_spin_box(1, 100, 50)
        self.top_k.setToolTip("Consider only the top K moves with the highest probability.")
        policy_layout.addRow("Top K:", self.top_k)

        self.top_p = create_double_spin_box(0.1, 1.0, 1.0, 0.05)
        self.top_p.setToolTip("Considers moves from the smallest set whose cumulative probability exceeds P.")
        policy_layout.addRow("Top P:", self.top_p)

        self.min_p = create_double_spin_box(0.0, 1.0, 0.05, 0.01)
        self.min_p.setToolTip(
            "Consider only moves with a probability of at least P times the probability of the best move."
        )
        policy_layout.addRow("Min P:", self.min_p)

        self.addWidget(policy_group)

        # --- Analysis Settings Group ---
        analysis_group = QGroupBox("Analysis Settings")
        analysis_layout = QFormLayout(analysis_group)

        analysis_explanation = QLabel(
            "Controls the AI's strength for board analysis and for when it's asked to play the best move (not sampling)."
        )
        analysis_explanation.setWordWrap(True)
        analysis_layout.addRow(analysis_explanation)

        self.visits = create_spin_box(8, 1024, 24)
        self.visits.setToolTip("The number of playouts the AI will perform. Higher values are stronger but slower.")
        analysis_layout.addRow("Visits:", self.visits)

        self.addWidget(analysis_group)

        # --- Mistake Feedback Group ---
        mistake_group = QGroupBox("Mistake Feedback Settings")
        v_layout = QVBoxLayout(mistake_group)

        explanation = QLabel("Halt auto-play if the last human move was a mistake where:")
        explanation.setWordWrap(True)
        v_layout.addWidget(explanation)

        # Mistake size
        h_layout_mistake = QHBoxLayout()
        h_layout_mistake.addSpacing(20)
        h_layout_mistake.addWidget(QLabel("Mistake size >"))
        self.mistake_size_spinbox = create_spin_box(0, 100, 1)
        self.mistake_size_spinbox.setToolTip("The minimum score loss for a move to be considered a mistake.")
        h_layout_mistake.addWidget(self.mistake_size_spinbox)
        h_layout_mistake.addWidget(QLabel("points"))
        h_layout_mistake.addStretch()
        v_layout.addLayout(h_layout_mistake)

        and_label = QLabel("<b>AND</b> one of the following is true:")
        and_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        v_layout.addWidget(and_label)

        # Probabilities
        v_layout_probs = QVBoxLayout()
        v_layout_probs.setContentsMargins(20, 0, 0, 0)  # Indent the whole block

        # Target rank
        h_layout_target = QHBoxLayout()
        h_layout_target.addWidget(QLabel("Move's rank probability <"))
        self.target_rank_spinbox = create_spin_box(0, 100, 20)
        self.target_rank_spinbox.setToolTip("Halt if the move is very unlikely for the target rank.")
        h_layout_target.addWidget(self.target_rank_spinbox)
        h_layout_target.addWidget(QLabel("%"))
        h_layout_target.addStretch()
        v_layout_probs.addLayout(h_layout_target)

        or_label = QLabel("<b>OR</b>")
        or_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        v_layout_probs.addWidget(or_label)

        # Policy prob
        h_layout_policy = QHBoxLayout()
        h_layout_policy.addWidget(QLabel("Move's policy probability <"))
        self.max_probability_spinbox = create_spin_box(0, 5, 1)
        self.max_probability_spinbox.setToolTip("Halt if the move is not among the top moves considered by any policy.")
        h_layout_policy.addWidget(self.max_probability_spinbox)
        h_layout_policy.addWidget(QLabel("%"))
        h_layout_policy.addStretch()
        v_layout_probs.addLayout(h_layout_policy)

        v_layout.addLayout(v_layout_probs)

        self.addWidget(mistake_group)

        self.addStretch(1)

    def connect_signals(self):
        for widget in [
            self.top_k,
            self.top_p,
            self.min_p,
            self.visits,
            self.mistake_size_spinbox,
            self.target_rank_spinbox,
            self.max_probability_spinbox,
        ]:
            widget.valueChanged.connect(self.on_settings_changed)

    def get_ai_strength(self):
        return self.visits.value()

    def get_sampling_settings(self):
        return {
            "top_k": self.top_k.value(),
            "top_p": self.top_p.value(),
            "min_p": self.min_p.value(),
        }

    def should_halt_on_mistake(self, move_stats) -> str | None:
        if move_stats:
            max_prob = max(move_stats[f"{k}_prob"] for k in ["player", "target", "ai"])
            mistake_size = move_stats["mistake_size"]
            target_rank_prob = move_stats["move_like_target"]

            if mistake_size > self.mistake_size_spinbox.value():
                mistake_size_msg = f"Mistake size ({mistake_size:.2f}) > {self.mistake_size_spinbox.value()} points"
                if max_prob < self.max_probability_spinbox.value() / 100:
                    return f"Max policy probability ({max_prob:.1%}) < {self.max_probability_spinbox.value()}% and {mistake_size_msg}"
                if target_rank_prob < self.target_rank_spinbox.value() / 100:
                    return f"Target rank probability ({target_rank_prob:.1%}) < {self.target_rank_spinbox.value()}% and {mistake_size_msg}"
        return None
