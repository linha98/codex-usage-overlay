from __future__ import annotations

import queue
import threading
from typing import Any

try:
    import win32api
    import win32con
    import win32gui
except ImportError:  # 开发环境缺少 pywin32 时仍可显示主窗口
    win32api = None
    win32con = None
    win32gui = None


class TrayIcon:
    def __init__(self, actions: "queue.Queue[str]") -> None:
        self.actions = actions
        self._thread: threading.Thread | None = None
        self._hwnd: int | None = None
        self._tooltip = "Codex 用量悬浮窗"
        self.click_through = False
        self.autostart = False

    @property
    def available(self) -> bool:
        return win32gui is not None

    def start(self) -> None:
        if not self.available or (self._thread and self._thread.is_alive()):
            return
        self._thread = threading.Thread(target=self._run, name="codex-tray", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        if self._hwnd and win32gui:
            win32gui.PostMessage(self._hwnd, win32con.WM_CLOSE, 0, 0)

    def update_tooltip(self, text: str) -> None:
        tooltip = text[:120]
        if tooltip == self._tooltip:
            return
        self._tooltip = tooltip
        if self._hwnd and win32gui:
            try:
                win32gui.Shell_NotifyIcon(
                    win32gui.NIM_MODIFY,
                    (
                        self._hwnd,
                        0,
                        win32gui.NIF_MESSAGE | win32gui.NIF_ICON | win32gui.NIF_TIP,
                        win32con.WM_USER + 20,
                        win32gui.LoadIcon(0, win32con.IDI_APPLICATION),
                        self._tooltip,
                    ),
                )
            except win32gui.error:
                pass

    def _run(self) -> None:
        assert win32gui and win32con and win32api
        message_id = win32con.WM_USER + 20
        class_name = f"CodexUsageOverlayTray_{win32api.GetCurrentProcessId()}"
        message_map = {
            message_id: self._on_tray,
            win32con.WM_COMMAND: self._on_command,
            win32con.WM_CLOSE: self._on_close,
            win32con.WM_DESTROY: self._on_destroy,
        }
        window_class = win32gui.WNDCLASS()
        window_class.hInstance = win32api.GetModuleHandle(None)
        window_class.lpszClassName = class_name
        window_class.lpfnWndProc = message_map
        try:
            win32gui.RegisterClass(window_class)
        except win32gui.error:
            pass
        self._hwnd = win32gui.CreateWindow(
            class_name,
            "CodexUsageOverlayTray",
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            window_class.hInstance,
            None,
        )
        self._add_icon()
        win32gui.PumpMessages()

    def _add_icon(self) -> None:
        assert self._hwnd and win32gui and win32con
        icon = win32gui.LoadIcon(0, win32con.IDI_APPLICATION)
        win32gui.Shell_NotifyIcon(
            win32gui.NIM_ADD,
            (
                self._hwnd,
                0,
                win32gui.NIF_MESSAGE | win32gui.NIF_ICON | win32gui.NIF_TIP,
                win32con.WM_USER + 20,
                icon,
                self._tooltip,
            ),
        )

    def _on_tray(self, hwnd: int, msg: int, wparam: int, lparam: int) -> int:
        assert win32con
        if lparam == win32con.WM_LBUTTONDBLCLK:
            self.actions.put("show")
        elif lparam in (win32con.WM_RBUTTONUP, win32con.WM_CONTEXTMENU):
            self._show_menu(hwnd)
        return 0

    def _show_menu(self, hwnd: int) -> None:
        assert win32gui and win32con
        menu = win32gui.CreatePopupMenu()
        win32gui.AppendMenu(menu, win32con.MF_STRING, 1, "显示悬浮窗")
        win32gui.AppendMenu(menu, win32con.MF_STRING, 2, "立即刷新")
        win32gui.AppendMenu(menu, win32con.MF_SEPARATOR, 0, None)
        win32gui.AppendMenu(
            menu,
            win32con.MF_STRING | (win32con.MF_CHECKED if self.click_through else 0),
            3,
            "鼠标穿透",
        )
        win32gui.AppendMenu(
            menu,
            win32con.MF_STRING | (win32con.MF_CHECKED if self.autostart else 0),
            4,
            "开机启动",
        )
        win32gui.AppendMenu(menu, win32con.MF_SEPARATOR, 0, None)
        win32gui.AppendMenu(menu, win32con.MF_STRING, 5, "退出")
        position = win32gui.GetCursorPos()
        win32gui.SetForegroundWindow(hwnd)
        win32gui.TrackPopupMenu(
            menu,
            win32con.TPM_LEFTALIGN | win32con.TPM_BOTTOMALIGN,
            position[0],
            position[1],
            0,
            hwnd,
            None,
        )
        win32gui.PostMessage(hwnd, win32con.WM_NULL, 0, 0)

    def _on_command(self, hwnd: int, msg: int, wparam: int, lparam: int) -> int:
        assert win32api
        command = win32api.LOWORD(wparam)
        actions = {1: "show", 2: "refresh", 3: "click_through", 4: "autostart", 5: "exit"}
        action = actions.get(command)
        if action:
            self.actions.put(action)
        return 0

    def _on_close(self, hwnd: int, msg: int, wparam: int, lparam: int) -> int:
        assert win32gui
        win32gui.DestroyWindow(hwnd)
        return 0

    def _on_destroy(self, hwnd: int, msg: int, wparam: int, lparam: int) -> int:
        assert win32gui
        try:
            win32gui.Shell_NotifyIcon(win32gui.NIM_DELETE, (hwnd, 0))
        except win32gui.error:
            pass
        self._hwnd = None
        win32gui.PostQuitMessage(0)
        return 0
