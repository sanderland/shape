import argparse
import signal
import sys
import traceback

from PySide6.QtWidgets import QApplication, QMessageBox

from shape.katago.engine import KataGoEngine
from shape.ui.main_window import MainWindow
from shape.utils import setup_logging

logger = setup_logging()

signal.signal(signal.SIGINT, signal.SIG_DFL)  # hard exit on SIGINT


def show_error_dialog(exc_type, exc_value, exc_tb):
    """Show a dialog for unhandled exceptions."""
    tb_str = "".join(traceback.format_exception(exc_type, exc_value, exc_tb))
    error_message = f"An unexpected error occurred:\n\n{exc_value}\n\nTraceback:\n{tb_str}"
    logger.error(error_message)

    # Ensure QApplication instance exists
    if QApplication.instance() is None:
        _ = QApplication(sys.argv)

    msg_box = QMessageBox()
    msg_box.setIcon(QMessageBox.Icon.Critical)
    msg_box.setText("An unexpected error occurred.")
    msg_box.setInformativeText(str(exc_value))
    msg_box.setDetailedText(tb_str)
    msg_box.setWindowTitle("Error")
    msg_box.exec()
    sys.exit(1)


class SHAPEApp:
    def __init__(self):
        self.app = QApplication(sys.argv)
        self.main_window = MainWindow()

        self.katago = KataGoEngine()
        self.main_window.set_engine(self.katago)

    def run(self):
        self.main_window.show()
        return self.app.exec()


def main():
    sys.excepthook = show_error_dialog
    parser = argparse.ArgumentParser(description="SHAPE: Shape Habits Analysis and Personalized Evaluation")
    parser.parse_args()

    shape = SHAPEApp()
    sys.exit(shape.run())


if __name__ == "__main__":
    main()
