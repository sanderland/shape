import argparse
import signal
import sys

from PySide6.QtWidgets import QApplication

from shape.katago.engine import KataGoEngine
from shape.ui.main_window import MainWindow
from shape.utils import setup_logging

logger = setup_logging()

signal.signal(signal.SIGINT, signal.SIG_DFL)  # hard exit on SIGINT


class SHAPEApp:
    def __init__(self):
        self.app = QApplication(sys.argv)
        self.main_window = MainWindow()

        try:
            self.katago = KataGoEngine()
        except Exception as e:
            self.show_error(f"Failed to initialize KataGo engine: {e}")
            sys.exit(1)

        self.main_window.set_engine(self.katago)

    def run(self):
        self.main_window.show()
        return self.app.exec()

    def show_error(self, message):
        logger.error(message)


def main():
    parser = argparse.ArgumentParser(description="SHAPE: Shape Habits Analysis and Personalized Evaluation")
    parser.parse_args()

    shape = SHAPEApp()
    sys.exit(shape.run())


if __name__ == "__main__":
    main()
