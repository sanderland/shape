from shape.ui.ui_utils import (
    SettingsTab,
    create_config_section,
    create_double_spin_box,
    create_spin_box,
)


class ConfigPanel(SettingsTab):
    def create_widgets(self):
        self.top_k = create_spin_box(1, 100, 50)
        self.top_p = create_double_spin_box(0.1, 1.0, 1.0, 0.05)
        self.min_p = create_double_spin_box(0.0, 1.0, 0.05, 0.01)
        self.addWidget(
            create_config_section(
                "Policy Sampling Settings",
                {
                    "Top K:": self.top_k,
                    "Top P:": self.top_p,
                    "Min P:": self.min_p,
                },
                note="These settings affect both opponent move selection and the heatmap visualization.",
            )
        )
        self.visits = create_spin_box(8, 1024, 24)
        self.addWidget(create_config_section("Analysis Settings", {"Visits:": self.visits}))
        self.mistake_size_spinbox = create_spin_box(0, 100, 1)
        self.target_rank_spinbox = create_spin_box(0, 100, 20)
        self.max_probability_spinbox = create_spin_box(0, 5, 1)
        self.addWidget(
            create_config_section(
                "Mistake Feedback Settings. Halt if:",
                {
                    "Mistake size > (points)": self.mistake_size_spinbox,
                    "Either Target rank probability < (%)": self.target_rank_spinbox,
                    "Or Max policy probability < (%)": self.max_probability_spinbox,
                },
            )
        )
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
