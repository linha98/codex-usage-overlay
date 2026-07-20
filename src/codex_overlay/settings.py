from __future__ import annotations

import json
import os
import sys
import tempfile
import winreg
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


APP_NAME = "CodexUsageOverlay"
RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"


@dataclass
class AppSettings:
    x: int | None = None
    y: int | None = None
    opacity: float = 0.94
    compact: bool = False
    click_through: bool = False
    autostart: bool = False

    @classmethod
    def load(cls) -> "AppSettings":
        path = settings_path()
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return cls(autostart=is_autostart_enabled())
        if not isinstance(data, dict):
            return cls(autostart=is_autostart_enabled())
        values: dict[str, Any] = {}
        for key in ("x", "y", "opacity", "compact", "click_through"):
            if key in data:
                values[key] = data[key]
        values["autostart"] = is_autostart_enabled()
        settings = cls(**values)
        settings.opacity = max(0.55, min(1.0, float(settings.opacity)))
        return settings

    def save(self) -> None:
        path = settings_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = json.dumps(asdict(self), ensure_ascii=False, indent=2)
        fd, temp_name = tempfile.mkstemp(prefix="settings-", suffix=".json", dir=path.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                stream.write(payload)
            os.replace(temp_name, path)
        finally:
            if os.path.exists(temp_name):
                os.unlink(temp_name)


def settings_path() -> Path:
    local = os.environ.get("LOCALAPPDATA")
    root = Path(local) if local else Path.home() / "AppData" / "Local"
    return root / APP_NAME / "settings.json"


def is_autostart_enabled() -> bool:
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
            winreg.QueryValueEx(key, APP_NAME)
        return True
    except OSError:
        return False


def set_autostart(enabled: bool) -> bool:
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
        if enabled:
            if getattr(sys, "frozen", False):
                command = f'"{sys.executable}" --startup'
            else:
                command = f'"{sys.executable}" -m codex_overlay --startup'
            winreg.SetValueEx(key, APP_NAME, 0, winreg.REG_SZ, command)
        else:
            try:
                winreg.DeleteValue(key, APP_NAME)
            except FileNotFoundError:
                pass
    return is_autostart_enabled()
