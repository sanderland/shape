import asyncio
import os
import platform
import shutil
import subprocess
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

import httpx
from PySide6.QtCore import QThread, Signal
from PySide6.QtGui import QFont
from PySide6.QtWidgets import (
    QDialog,
    QHBoxLayout,
    QLabel,
    QProgressBar,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from shape.utils import setup_logging

logger = setup_logging()

KATRAIN_DIR = Path.home() / ".katrain"


def get_katago_version_info(katago_path: Path) -> tuple[str, str]:
    """Get KataGo version and backend info. Returns (version, backend)."""
    try:
        result = subprocess.run([str(katago_path), "version"], capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            lines = result.stdout.strip().split("\n")
            version = "Unknown"
            backend = "Unknown"

            for line in lines:
                if line.startswith("KataGo v"):
                    version = line.split()[1]  # Extract version like "v1.15.3"
                elif "backend" in line.lower():
                    # Extract backend like "OpenCL", "CUDA", etc.
                    if "OpenCL" in line:
                        backend = "OpenCL"
                    elif "CUDA" in line:
                        backend = "CUDA"
                    elif "CPU" in line:
                        backend = "CPU"
                    else:
                        backend = line.split()[-1]  # Last word of the line

            return version, backend
        else:
            logger.warning(f"KataGo version command failed: {result.stderr}")
            return "Unknown", "Unknown"
    except Exception as e:
        logger.warning(f"Failed to get KataGo version: {e}")
        return "Unknown", "Unknown"


KATAGO_DIR = KATRAIN_DIR / "katago"
KATAGO_EXE_NAME = "katago.exe" if platform.system() == "Windows" else "katago"
KATAGO_PATH = KATAGO_DIR / KATAGO_EXE_NAME


@dataclass
class DownloadableComponent:
    name: str
    destination_dir: Path
    destination_filename: str
    download_url: str
    is_zip: bool = False
    found: bool = field(init=False, default=False)
    downloading: bool = field(init=False, default=False)
    error: str | None = field(init=False, default=None)

    def __post_init__(self):
        self.destination_dir.mkdir(parents=True, exist_ok=True)
        self.check_if_found()

    @property
    def destination_path(self) -> Path:
        return self.destination_dir / self.destination_filename

    def check_if_found(self):
        # Special case for KataGo: check PATH first
        if self.name == "KataGo Engine":
            path_katago = shutil.which("katago")
            if path_katago:
                self.found = True
                self.error = None
                # Update destination to point to the PATH version
                self._path_katago = Path(path_katago)
                return True

        self.found = self.destination_path.exists()
        if self.found:
            self.error = None  # reset error on found
        return self.found

    def get_widget(self, download_callback, parent_dialog) -> "ComponentWidget":
        return ComponentWidget(self, download_callback, parent_dialog)


class ComponentWidget(QWidget):
    def __init__(self, component: DownloadableComponent, download_callback, parent: QDialog):
        super().__init__(parent)
        self.component = component
        self.download_callback = download_callback

        layout = QHBoxLayout()
        self.name_label = QLabel(f"<b>{component.name}</b>")
        self.status_label = QLabel()
        self.download_button = QPushButton()
        self.download_button.clicked.connect(self._on_download_click)
        self.progress_bar = QProgressBar()
        self.progress_bar.setVisible(False)

        layout.addWidget(self.name_label)
        layout.addWidget(self.status_label)
        layout.addStretch()
        layout.addWidget(self.progress_bar)
        layout.addWidget(self.download_button)
        self.setLayout(layout)
        self.update_status()

    def _on_download_click(self):
        self.download_button.setEnabled(False)
        self.progress_bar.setVisible(True)
        self.progress_bar.setRange(0, 0)
        self.download_callback(self.component)

    def update_status(self):
        self.component.check_if_found()
        if self.component.downloading:
            self.status_label.setText("Downloading...")
            self.download_button.setVisible(False)
            self.progress_bar.setVisible(True)
        elif self.component.found:
            if self.component.name == "KataGo Engine":
                # Show version info for KataGo
                if hasattr(self.component, "_path_katago"):
                    katago_path = self.component._path_katago
                    location_text = f"Found in PATH: {katago_path}"
                else:
                    katago_path = self.component.destination_path
                    location_text = f"Found at {katago_path}"

                version, backend = get_katago_version_info(katago_path)
                self.status_label.setText(
                    f"<font color='green'>{location_text}<br/>Version: {version} ({backend})</font>"
                )
            else:
                # For models, show file info
                if hasattr(self.component, "_path_katago"):
                    self.status_label.setText(
                        f"<font color='green'>Found in PATH: {self.component._path_katago}</font>"
                    )
                else:
                    file_size = (
                        self.component.destination_path.stat().st_size // (1024 * 1024)
                        if self.component.destination_path.exists()
                        else 0
                    )
                    self.status_label.setText(
                        f"<font color='green'>Found at {self.component.destination_path}<br/>Size: {file_size} MB</font>"
                    )
            self.download_button.setVisible(False)
            self.progress_bar.setVisible(False)
        elif self.component.error:
            self.status_label.setText(f"<font color='red'>Error: {self.component.error}</font>")
            self.download_button.setText("Retry")
            self.download_button.setVisible(True)
            self.download_button.setEnabled(True)
            self.progress_bar.setVisible(False)
        else:
            self.status_label.setText("<font color='orange'>Missing</font>")
            self.download_button.setText("Download")
            self.download_button.setVisible(True)
            self.download_button.setEnabled(True)
            self.progress_bar.setVisible(False)

    def update_progress(self, percent):
        self.progress_bar.setRange(0, 100)
        self.progress_bar.setValue(percent)


class DownloadThread(QThread):
    progress_signal = Signal(DownloadableComponent, int)
    finished_signal = Signal(DownloadableComponent, str)  # Component, error_message (empty string for success)

    def __init__(self, components_to_download: list[DownloadableComponent]):
        super().__init__()
        self.components = components_to_download
        for c in self.components:
            c.downloading = True

    def run(self):
        try:
            asyncio.run(self._download_files_async())
        except Exception as e:
            logger.error(f"Downloader thread failed: {e}")
            for component in self.components:  # fail all on thread error
                if component.downloading:
                    self.finished_signal.emit(component, str(e))

    async def _download_files_async(self):
        async with httpx.AsyncClient(timeout=300.0) as client:
            tasks = [self._download_file(client, c) for c in self.components]
            results = await asyncio.gather(*tasks, return_exceptions=True)

            for component, result in zip(self.components, results, strict=False):
                if isinstance(result, Exception):
                    self.finished_signal.emit(component, str(result))
                else:
                    self.finished_signal.emit(component, "")

    async def _download_file(self, client: httpx.AsyncClient, component: DownloadableComponent):
        download_path = (
            component.destination_path.with_suffix(".zip.download")
            if component.is_zip
            else component.destination_path.with_suffix(".download")
        )
        try:
            async with client.stream("GET", component.download_url, follow_redirects=True) as response:
                response.raise_for_status()
                total_size = int(response.headers.get("content-length", 0))
                with open(download_path, "wb") as f:
                    downloaded = 0
                    async for chunk in response.aiter_bytes(chunk_size=8192):
                        f.write(chunk)
                        downloaded += len(chunk)
                        if total_size > 0:
                            percent = min(100, (downloaded * 100) // total_size)
                            self.progress_signal.emit(component, percent)

            if component.is_zip:
                with zipfile.ZipFile(download_path, "r") as zip_ref:
                    # find executable in zip
                    exe_files = [
                        f for f in zip_ref.namelist() if f.endswith(KATAGO_EXE_NAME) and not f.startswith("__MACOSX")
                    ]
                    if not exe_files:
                        raise Exception(f"Katago executable not found in zip {download_path}")
                    internal_exe_path = exe_files[0]
                    with zip_ref.open(internal_exe_path) as source, open(component.destination_path, "wb") as target:
                        shutil.copyfileobj(source, target)
                os.chmod(component.destination_path, 0o755)  # make executable
            else:
                shutil.move(download_path, component.destination_path)

        finally:
            if download_path.exists():
                download_path.unlink()


class ComponentsDownloaderDialog(QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("SHAPE Setup: KataGo Components")
        self.setModal(True)
        self.setMinimumWidth(600)

        self.components = self._define_components()
        self.component_widgets: dict[str, ComponentWidget] = {}
        self.setup_ui()
        self.check_all_found()

    def _get_katago_url(self):
        system = platform.system()
        base_url = "https://github.com/lightvector/KataGo/releases/download/v1.16.0/"
        if system == "Linux":
            return base_url + "katago-v1.16.0-opencl-linux-x64.zip"
        elif system == "Windows":
            return base_url + "katago-v1.16.0-opencl-windows-x64.zip"
        elif system == "Darwin":  # MacOS
            return base_url + "katago-v1.16.0-opencl-macos-x64.zip"
        raise RuntimeError(f"Unsupported OS for KataGo download: {system}")

    def _define_components(self) -> list[DownloadableComponent]:
        return [
            DownloadableComponent(
                name="KataGo Engine",
                destination_dir=KATAGO_DIR,
                destination_filename=KATAGO_EXE_NAME,
                download_url=self._get_katago_url(),
                is_zip=True,
            ),
            DownloadableComponent(
                name="KataGo Model (28b)",
                destination_dir=KATRAIN_DIR,
                destination_filename="katago-28b.bin.gz",
                download_url="https://media.katagotraining.org/uploaded/networks/models/kata1/kata1-b28c512nbt-s7709128960-d4462231357.bin.gz",
            ),
            DownloadableComponent(
                name="KataGo Model (Human)",
                destination_dir=KATRAIN_DIR,
                destination_filename="katago-human.bin.gz",
                download_url="https://github.com/lightvector/KataGo/releases/download/v1.15.0/b18c384nbt-humanv0.bin.gz",
            ),
        ]

    def setup_ui(self):
        layout = QVBoxLayout()
        self.title_label = QLabel("Checking for required components...")
        font = QFont()
        font.setPointSize(16)
        font.setBold(True)
        self.title_label.setFont(font)
        layout.addWidget(self.title_label)

        for component in self.components:
            widget = component.get_widget(self.download_one, self)
            self.component_widgets[component.name] = widget
            layout.addWidget(widget)

        self.download_all_button = QPushButton("Download All Missing")
        self.download_all_button.clicked.connect(self.download_all)
        layout.addWidget(self.download_all_button)

        self.close_button = QPushButton("Close")
        self.close_button.clicked.connect(self.accept)
        layout.addWidget(self.close_button)

        self.setLayout(layout)

    def download_one(self, component: DownloadableComponent):
        self.download([component])

    def download_all(self):
        missing = [c for c in self.components if not c.found]
        self.download(missing)

    def download(self, components: list[DownloadableComponent]):
        if not components:
            return
        self.download_all_button.setEnabled(False)
        self.close_button.setEnabled(False)

        self.download_thread = DownloadThread(components)
        for c in components:
            self.component_widgets[c.name].update_status()
        self.download_thread.progress_signal.connect(self._on_progress)
        self.download_thread.finished_signal.connect(self._on_finished)
        self.download_thread.start()

    def _on_progress(self, component: DownloadableComponent, percent: int):
        self.component_widgets[component.name].update_progress(percent)

    def _on_finished(self, component: DownloadableComponent, error: str):
        component.downloading = False
        component.error = error if error else None
        component.check_if_found()
        # Force progress bar to be hidden and reset
        widget = self.component_widgets[component.name]
        widget.progress_bar.setVisible(False)
        widget.progress_bar.setRange(0, 100)
        widget.progress_bar.setValue(0)
        widget.update_status()
        self.check_all_found()

    def check_all_found(self):
        all_found = all(c.check_if_found() for c in self.components)
        downloading = any(c.downloading for c in self.components)

        # Update title based on status
        if downloading:
            self.title_label.setText("Downloading components...")
        elif all_found:
            self.title_label.setText("All components ready!")
        else:
            missing_count = sum(1 for c in self.components if not c.found)
            self.title_label.setText(f"Missing {missing_count} component{'s' if missing_count != 1 else ''}")

        self.download_all_button.setEnabled(not all_found and not downloading)
        self.close_button.setEnabled(all_found and not downloading)
        self.close_button.setText("Continue" if all_found else "Close")
        if all_found:
            self.download_all_button.setVisible(False)

    def get_paths(self) -> dict[str, Path] | None:
        if not all(c.found for c in self.components):
            return None

        # Get KataGo path - either from PATH or downloaded location
        katago_component = self.components[0]  # KataGo Engine is first
        if hasattr(katago_component, "_path_katago"):
            katago_path = katago_component._path_katago
        else:
            katago_path = KATAGO_PATH

        return {
            "katago_path": katago_path,
            "model_path": self.components[1].destination_path,
            "human_model_path": self.components[2].destination_path,
        }

    def get_katago_version_info(self) -> tuple[str, str]:
        """Get KataGo version and backend info for the main window title."""
        katago_component = self.components[0]  # KataGo Engine is first
        if not katago_component.found:
            return "Unknown", "Unknown"

        if hasattr(katago_component, "_path_katago"):
            katago_path = katago_component._path_katago
        else:
            katago_path = KATAGO_PATH

        return get_katago_version_info(katago_path)
