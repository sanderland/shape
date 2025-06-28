import logging

import numpy as np
from PySide6.QtCore import QEvent, Qt, QTimer, Signal
from PySide6.QtGui import QAction
from PySide6.QtWidgets import (
    QApplication,
    QFileDialog,
    QHBoxLayout,
    QLabel,
    QMainWindow,
    QMenu,
    QMenuBar,
    QStatusBar,
    QTabWidget,
    QVBoxLayout,
    QWidget,
)

from shape.game_logic import GameLogic, Move
from shape.ui.board_view import BoardView
from shape.ui.tab_analysis import AnalysisPanel
from shape.ui.tab_config import ConfigPanel
from shape.ui.tab_main_control import ControlPanel
from shape.ui.ui_utils import MAIN_STYLESHEET
from shape.utils import setup_logging

logger = setup_logging()


class MainWindow(QMainWindow):
    update_state_main_thread = Signal()

    def __init__(self):
        super().__init__()
        self.setStyleSheet(MAIN_STYLESHEET)
        self.katago_engine = None
        self.game_logic = GameLogic()
        self.setWindowTitle("SHAPE - Play Go with AI Feedback")
        self.setFocusPolicy(Qt.StrongFocus)
        self.setup_ui()
        self.connect_signals()

        self.update_state_timer = QTimer(self)
        self.update_state_timer.setSingleShot(True)
        self.update_state_timer.timeout.connect(self._update_state)

    def set_engine(self, katago_engine):
        self.katago_engine = katago_engine
        # Update window title with version info
        try:
            from importlib.metadata import version

            shape_version = version("goshape")
        except ImportError:
            shape_version = "dev"  # Fallback for development
        katago_version = getattr(katago_engine, "katago_version", "Unknown")
        katago_backend = getattr(katago_engine, "katago_backend", "Unknown")
        self.setWindowTitle(f"SHAPE v{shape_version} running KataGo {katago_version} ({katago_backend})")
        self.update_state()

    def set_logging_level(self, level):
        logger.setLevel(level)
        logging.getLogger().setLevel(level)

    def connect_signals(self):
        self.control_panel.ai_move_button.clicked.connect(self.request_ai_move)
        self.config_panel.settings_updated.connect(self.update_state)
        self.control_panel.settings_updated.connect(self.update_state)
        self.update_state_main_thread.connect(self.update_state)

    def update_state(self):
        self.update_state_timer.start(100)  # 100ms debounce

    def _update_state(self):
        current_node = self.game_logic.current_node
        human_profiles, current_analysis = self.ensure_analysis_requested(current_node)
        next_player_human = self.control_panel.get_player_color() == self.game_logic.next_player
        # halt auto-play if
        if not self.game_logic.game_ended() and all(current_analysis.values()):
            if not next_player_human and (
                should_halt_reason := self.config_panel.should_halt_on_mistake(
                    self.control_panel.get_move_stats(current_node)
                )
            ):
                current_node.autoplay_halted_reason = should_halt_reason
                logger.info(f"Halting auto-play due to {should_halt_reason}.")
            else:
                self.maybe_make_ai_move(current_node, human_profiles, current_analysis, next_player_human)

        for tab in [self.control_panel, self.analysis_panel, self.config_panel]:
            tab.update_ui()
        self.board_view.update()

    def maybe_make_ai_move(self, current_node, human_profiles, current_analysis, next_player_human):
        if (
            not current_node.children and self.control_panel.is_auto_play_enabled() and not next_player_human
        ) or current_node.ai_move_requested:
            current_node.ai_move_requested = False
            policy_moves, reason = current_analysis[human_profiles["opponent"]].human_policy.sample(
                **self.config_panel.get_sampling_settings()
            )
            best_ai_move = current_analysis[None].ai_moves()[0]["move"]
            if policy_moves:
                if best_ai_move == "pass":
                    logger.info("Passing because it is the best AI move")
                    self.make_move(None)
                else:
                    moves, probs, _ = zip(*policy_moves, strict=False)
                    move = np.random.choice(moves, p=np.array(probs) / sum(probs))
                    logger.info(f"Making sampled move: {move} from {len(policy_moves)} cuttoff due to {reason}")
                    self.make_move(move.coords)
            else:
                logger.info("No valid moves available, passing")
                self.make_move(None)

    # actions
    def make_move(self, coords: tuple[int, int] | None):
        if self.game_logic.make_move(Move(coords=coords, player=self.game_logic.next_player)):
            self.update_state()

    def on_prev_move(self, n=1):
        self.game_logic.undo_move(n)
        self.update_state()

    def on_next_move(self, n=1):
        self.game_logic.redo_move(n)
        self.update_state()

    def request_ai_move(self):
        self.game_logic.current_node.ai_move_requested = True
        self.update_status_bar("AI move requested")
        self.update_state()

    def new_game(self, size):
        logger.info(f"New game requested with size: {size}")
        self.game_logic.new_game(size)
        self.update_state()

    def copy_sgf_to_clipboard(self):
        self.save_as_sgf(to_clipboard=True)

    def save_as_sgf(self, to_clipboard: bool = False):
        def get_player_name(color):
            if self.control_panel.get_player_color() == color:
                return "Human"
            else:
                profile = self.control_panel.get_human_profiles()["opponent"]
                return f"AI ({profile})" if profile else "KataGo"

        player_names = {bw: get_player_name(bw) for bw in "BW"}
        sgf_data = self.game_logic.export_sgf(player_names)

        if to_clipboard:
            clipboard = QApplication.clipboard()
            clipboard.setText(sgf_data)
            self.update_status_bar(f"SGF of length {len(sgf_data)} with {player_names} copied to clipboard.")
        else:
            file_path, _ = QFileDialog.getSaveFileName(self, "Save SGF File", "", "SGF Files (*.sgf)")
            if file_path:
                if not file_path.lower().endswith(".sgf"):
                    file_path += ".sgf"
                with open(file_path, "w") as f:
                    f.write(sgf_data)
                self.update_status_bar(f"SGF saved to {file_path}.")

    def paste_sgf_from_clipboard(self):
        clipboard = QApplication.clipboard()
        sgf_data = clipboard.text()
        if self.game_logic.import_sgf(sgf_data):
            self.update_state()
            self.update_status_bar("SGF imported successfully.")
            for node in self.game_logic.current_node.node_history:
                self.ensure_analysis_requested(node)
        else:
            self.update_status_bar("Failed to import SGF.")

    # analysis
    def ensure_analysis_requested(self, node):
        human_profiles = self.control_panel.get_human_profiles()
        current_analysis = {
            k: node.get_analysis(k)
            for k in [None, human_profiles["player"], human_profiles["opponent"], human_profiles["target"]]
        }
        for k, v in current_analysis.items():
            if not v and not node.analysis_requested(k):
                self.request_analysis(node, human_profile=k)
        return human_profiles, current_analysis

    def request_analysis(self, node, human_profile, force_visits=None):
        if node.analysis_requested(human_profile) and not force_visits:
            return

        logger.debug(f"Requesting analysis for {human_profile=} for {node=}")

        if human_profile:
            human_profile_settings = {
                "humanSLProfile": human_profile,
                "ignorePreRootHistory": False,
                "rootNumSymmetriesToSample": 8,  # max quality policy
            }
            max_visits = 1
        else:
            human_profile_settings = {}
            max_visits = force_visits or self.config_panel.get_ai_strength()

        if self.katago_engine:
            node.mark_analysis_requested(human_profile)
            self.katago_engine.analyze_position(
                node=node,
                callback=lambda resp: self.on_analysis_complete(node, resp, human_profile),
                human_profile_settings=human_profile_settings,
                max_visits=max_visits,
            )

    # this will be called from the engine thread
    def on_analysis_complete(self, node, analysis, human_profile):
        if "error" in analysis:
            logger.error(f"Analysis error: {analysis['error']}")
            self.update_status_bar(f"Analysis error: {analysis['error']}")
            if self.game_logic.current_node is node:
                self.game_logic.undo_move()
            logger.info(f"Deleting child node {node} because of analysis error => {node.parent.delete_child(node)}")
            return

        if human_profile is not None and "humanPolicy" not in analysis:
            logger.error(f"No human policy found in analysis: {analysis}")
        node.store_analysis(analysis, human_profile)
        num_queries = self.katago_engine.num_outstanding_queries()
        self.update_status_bar(
            "Ready"
            if num_queries == 0
            else f"{human_profile or 'AI'} analysis for {node.move.gtp() if node.move else 'root'} received, still working on {num_queries} queries"
        )

        if node == self.game_logic.current_node:  # update state in main thread
            self.update_state_main_thread.emit()

    # UI setup

    def setup_ui(self):
        self.create_menu_bar()
        self.create_status_bar()

        central_widget = QWidget()
        self.setCentralWidget(central_widget)

        main_layout = QHBoxLayout(central_widget)
        main_layout.setContentsMargins(0, 0, 0, 0)
        main_layout.setSpacing(0)

        self.board_view = BoardView(self)
        self.board_view.setFocusPolicy(Qt.StrongFocus)
        self.board_view.installEventFilter(self)
        main_layout.addWidget(self.board_view, 5)

        # Create a container for the right panel with proper margins
        right_panel_container = QWidget()
        right_panel_layout = QVBoxLayout(right_panel_container)
        right_panel_layout.setContentsMargins(0, 12, 0, 0)
        right_panel_layout.addWidget(self.create_right_panel_tabs())

        main_layout.addWidget(right_panel_container, 3)

        self.setMinimumSize(1200, 800)

    def create_right_panel_tabs(self):
        tab_widget = QTabWidget()

        # Play tab
        play_tab = QWidget()
        self.control_panel = ControlPanel(self)
        play_tab.setLayout(self.control_panel)
        tab_widget.addTab(play_tab, "Play")

        # AI Analysis tab
        ai_analysis_tab = QWidget()
        self.analysis_panel = AnalysisPanel(self)
        ai_analysis_tab.setLayout(self.analysis_panel)
        tab_widget.addTab(ai_analysis_tab, "AI Analysis")

        # Settings tab
        settings_tab = QWidget()
        self.config_panel = ConfigPanel(self)
        settings_tab.setLayout(self.config_panel)
        tab_widget.addTab(settings_tab, "Settings")
        return tab_widget

    def create_status_bar(self):
        status_bar = QStatusBar(self)
        self.setStatusBar(status_bar)
        self.status_label = QLabel("Ready")
        status_bar.addPermanentWidget(self.status_label)

    def update_status_bar(self, message):
        self.status_label.setText(message)

    def create_menu_bar(self):
        menu_bar = QMenuBar(self)
        self.setMenuBar(menu_bar)

        file_menu = QMenu("File", self)
        menu_bar.addMenu(file_menu)

        save_sgf_action = file_menu.addAction("Save as SGF")
        save_sgf_action.triggered.connect(self.save_as_sgf)
        save_sgf_action.setShortcut("Ctrl+S")

        save_sgf_to_clipboard_action = file_menu.addAction("SGF to Clipboard")
        save_sgf_to_clipboard_action.triggered.connect(self.copy_sgf_to_clipboard)
        save_sgf_to_clipboard_action.setShortcut("Ctrl+C")

        paste_sgf_action = file_menu.addAction("Paste SGF from Clipboard")
        paste_sgf_action.triggered.connect(self.paste_sgf_from_clipboard)
        paste_sgf_action.setShortcut("Ctrl+V")

        exit_action = file_menu.addAction("Exit")
        exit_action.triggered.connect(self.close)
        exit_action.setShortcut("Ctrl+Q")

        new_game_menu = QMenu("New Game", self)
        menu_bar.addMenu(new_game_menu)

        for size in [5, 9, 13, 19]:
            new_game_action = QAction(f"New Game ({size}x{size})", self)
            new_game_action.triggered.connect(lambda _checked, s=size: self.new_game(s))
            new_game_menu.addAction(new_game_action)

        # Add logging menu
        logging_menu = QMenu("Logging", self)
        menu_bar.addMenu(logging_menu)
        for level in ["DEBUG", "INFO", "WARNING", "ERROR"]:
            logging_action = QAction(level.capitalize(), self)
            logging_action.triggered.connect(lambda level=level: self.set_logging_level(level))
            logging_menu.addAction(logging_action)

    def on_pass_move(self):
        self.make_move(None)

    def eventFilter(self, obj, event):
        if obj == self.board_view and event.type() == QEvent.Wheel:
            if event.angleDelta().y() > 0:
                self.on_prev_move()
            elif event.angleDelta().y() < 0:
                self.on_next_move()
            return True
        return super().eventFilter(obj, event)
