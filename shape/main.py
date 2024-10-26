import os
import signal
import subprocess
import sys
import traceback

from PySide6.QtWidgets import QApplication

from shape.katago.engine import KataGoEngine
from shape.ui.main_window import MainWindow
from shape.utils import setup_logging

logger = setup_logging()

signal.signal(signal.SIGINT, signal.SIG_DFL)  # hard exit on SIGINT


def excepthook(cls, exception, traceback_obj):
    logger.error(f"Exception: {cls.__name__}: {exception}")
    logger.error("Traceback:")
    for line in traceback.format_tb(traceback_obj):
        logger.error(line.rstrip())


# sys.excepthook = excepthook


class SHAPEApp:
    def __init__(self):
        self.app = QApplication(sys.argv)
        self.main_window = MainWindow()

        # Use 'which katago' to find the KataGo executable
        try:
            katago_path = subprocess.check_output(["which", "katago"]).decode().strip()
        except subprocess.CalledProcessError:
            self.show_error("KataGo not found in PATH. Please install KataGo and make sure it's accessible.")
            sys.exit(1)

        # Ensure the 'models' directory exists
        models_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "models")
        if not os.path.exists(models_dir):
            self.show_error(
                f"'models' directory not found. Please create it at {models_dir} and add the required model files."
            )
            sys.exit(1)

        try:
            self.katago = KataGoEngine(katago_path)
        except Exception as e:
            self.show_error(f"Failed to initialize KataGo engine: {e}")
            sys.exit(1)

        self.main_window.set_engine(self.katago)

    def run(self):
        logger.debug("Application is starting...")  # Add this line
        self.main_window.show()
        return self.app.exec()

    def show_error(self, message):
        logger.error(message)

def main():
    stone = SHAPEApp()
    sys.exit(shape.run())


if __name__ == "__main__":
    main()
