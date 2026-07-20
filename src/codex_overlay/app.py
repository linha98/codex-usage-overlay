from __future__ import annotations

import ctypes
import queue
import sys
import tkinter as tk

from .codex_client import CodexAppServerClient
from .models import (
    LimitWindow,
    RateLimitSnapshot,
    ResetCreditsSnapshot,
    format_expiry_china,
    format_used_percent,
)
from .reset_credits_client import ResetCreditsClient
from .session_monitor import ActivitySnapshot, SessionActivityMonitor
from .settings import AppSettings, set_autostart
from .tray import TrayIcon


BG = "#15171C"
TEXT = "#F5F7FA"
MUTED = "#9097A3"
TRACK = "#303540"
GREEN = "#48D597"
BLUE = "#63A9FF"
AMBER = "#FFBF5B"


class OverlayApp:
    WIDTH = 168
    HEIGHT = 92

    def __init__(self, startup: bool = False, qa_window: bool = False) -> None:
        self.root = tk.Tk()
        self.root.title("Codex 悬浮窗")
        self.root.configure(bg=BG)
        self.root.overrideredirect(True)
        self.root.resizable(False, False)
        self.root.attributes("-topmost", True)
        self.settings = AppSettings.load()
        self.root.attributes("-alpha", self.settings.opacity)

        self.client = CodexAppServerClient()
        self.reset_client = ResetCreditsClient(refresh_seconds=3600)
        self.monitor = SessionActivityMonitor()
        self.tray_actions: queue.Queue[str] = queue.Queue()
        self.tray = TrayIcon(self.tray_actions)

        self.snapshot: RateLimitSnapshot | None = None
        self.reset_snapshot: ResetCreditsSnapshot | None = None
        self.reset_error: str | None = None
        self.activity = ActivitySnapshot("unknown", 0, "正在检查任务状态")
        self.connection_text = "正在连接 Codex"
        self.status_text = "检查中"
        self._usage_used = 0.0
        self._drag_offset = (0, 0)
        self._exiting = False

        self._build_ui()
        self._place_window()
        self.root.update_idletasks()
        apply_rounded_corners(self.root.winfo_id())
        if self.settings.click_through:
            self.root.after(300, lambda: self._set_click_through(True))
        if startup:
            self.root.after(500, self.root.deiconify)

    def run(self) -> None:
        self.client.start()
        self.reset_client.start()
        self.monitor.start()
        self.tray.click_through = self.settings.click_through
        self.tray.autostart = self.settings.autostart
        self.tray.start()
        self.root.after(100, self._pump_events)
        self.root.after(1000, self._tick)
        self.root.mainloop()

    def _build_ui(self) -> None:
        outer = tk.Frame(self.root, bg=BG, padx=8, pady=4)
        outer.pack(fill="both", expand=True)

        status_row = tk.Frame(outer, bg=BG)
        status_row.pack(fill="x")
        self.status_dot = tk.Label(
            status_row, text="●", bg=BG, fg=AMBER, font=("Segoe UI Symbol", 9)
        )
        self.status_dot.pack(side="left")
        self.status_label = tk.Label(
            status_row,
            text=self.status_text,
            bg=BG,
            fg=TEXT,
            font=("Microsoft YaHei UI", 9, "bold"),
        )
        self.status_label.pack(side="left", padx=(4, 0))

        usage_row = tk.Frame(outer, bg=BG)
        usage_row.pack(fill="x", pady=(5, 0))
        self.usage_label = tk.Label(
            usage_row, text="周用量", bg=BG, fg=MUTED, font=("Microsoft YaHei UI", 8)
        )
        self.usage_label.pack(side="left")
        self.usage_percent = tk.Label(
            usage_row, text="--", bg=BG, fg=TEXT, font=("Segoe UI", 8, "bold")
        )
        self.usage_percent.pack(side="right")

        self.usage_canvas = tk.Canvas(outer, width=1, height=3, bg=BG, highlightthickness=0)
        self.usage_canvas.pack(fill="x", pady=(2, 0))
        self.usage_canvas.bind("<Configure>", lambda _event: self._redraw_usage())

        reset_row = tk.Frame(outer, bg=BG)
        reset_row.pack(fill="x", pady=(6, 0))
        self.reset_count_label = tk.Label(
            reset_row, text="重置 --", bg=BG, fg=MUTED, font=("Microsoft YaHei UI", 8)
        )
        self.reset_count_label.pack(side="left")
        self.reset_expiry_label = tk.Label(
            reset_row, text="--", bg=BG, fg=MUTED, font=("Segoe UI", 8)
        )
        self.reset_expiry_label.pack(side="right")

        self._bind_surface(outer)

    def _bind_surface(self, widget: tk.Misc) -> None:
        widget.bind("<ButtonPress-1>", self._start_drag, add="+")
        widget.bind("<B1-Motion>", self._drag, add="+")
        widget.bind("<ButtonRelease-1>", self._end_drag, add="+")
        widget.bind("<Button-3>", self._show_context_menu, add="+")
        for child in widget.winfo_children():
            self._bind_surface(child)

    def _place_window(self) -> None:
        x = self.settings.x
        y = self.settings.y
        if x is None:
            x = self.root.winfo_screenwidth() - self.WIDTH - 28
        if y is None:
            y = 48
        self.root.geometry(f"{self.WIDTH}x{self.HEIGHT}{signed(x)}{signed(y)}")

    def _pump_events(self) -> None:
        if self._exiting:
            return
        while True:
            try:
                kind, value = self.client.events.get_nowait()
            except queue.Empty:
                break
            if kind == "usage" and isinstance(value, RateLimitSnapshot):
                self.snapshot = value
                self._render_usage(value.primary)
            elif kind == "connection":
                self.connection_text = str(value)

        while True:
            try:
                kind, value = self.reset_client.events.get_nowait()
            except queue.Empty:
                break
            if kind == "snapshot" and isinstance(value, ResetCreditsSnapshot):
                self.reset_snapshot = value
                self.reset_error = None
                self._render_reset()
            elif kind == "error":
                self.reset_error = str(value)
                self._render_reset()

        while True:
            try:
                self.activity = self.monitor.events.get_nowait()
            except queue.Empty:
                break
            self._render_activity()

        while True:
            try:
                action = self.tray_actions.get_nowait()
            except queue.Empty:
                break
            self._handle_action(action)

        self._update_tray_tooltip()
        self.root.after(150, self._pump_events)

    def _tick(self) -> None:
        if self._exiting:
            return
        self._redraw_usage()
        self.root.after(1000, self._tick)

    def _render_activity(self) -> None:
        if self.activity.status == "running":
            self.status_text = (
                "执行中" if self.activity.active_count == 1 else f"执行中 × {self.activity.active_count}"
            )
            color = GREEN
        elif self.activity.status == "idle":
            self.status_text = "空闲"
            color = BLUE
        else:
            self.status_text = "状态未知"
            color = AMBER
        self.status_label.configure(text=self.status_text)
        self.status_dot.configure(fg=color)

    def _render_usage(self, window: LimitWindow | None) -> None:
        if window is None:
            self.usage_label.configure(text="周用量")
            self.usage_percent.configure(text="--")
            self._usage_used = 0.0
        else:
            self.usage_label.configure(text=compact_window_label(window.window_duration_mins))
            self.usage_percent.configure(text=format_used_percent(window.used_percent))
            self._usage_used = window.used_percent
        self._redraw_usage()

    def _redraw_usage(self) -> None:
        width = max(1, self.usage_canvas.winfo_width())
        self.usage_canvas.delete("all")
        self.usage_canvas.create_rectangle(0, 0, width, 3, fill=TRACK, outline="")
        used_width = width * self._usage_used / 100.0
        self.usage_canvas.create_rectangle(0, 0, used_width, 3, fill=BLUE, outline="")

    def _render_reset(self) -> None:
        snapshot = self.reset_snapshot
        if snapshot is None:
            self.reset_count_label.configure(text="重置 --")
            self.reset_expiry_label.configure(text="--")
            return
        self.reset_count_label.configure(text=f"重置 {snapshot.available_count}次")
        self.reset_expiry_label.configure(text=format_expiry_china(snapshot.nearest_expiry_utc))

    def _update_tray_tooltip(self) -> None:
        parts = [f"Codex {self.status_text}"]
        if self.snapshot and self.snapshot.primary:
            parts.append(f"用量 {format_used_percent(self.snapshot.primary.used_percent)}")
        if self.reset_snapshot:
            parts.append(f"重置 {self.reset_snapshot.available_count}次")
        if not self.connection_text.startswith("已连接"):
            parts.append(self.connection_text)
        if self.reset_error:
            parts.append(self.reset_error)
        self.tray.update_tooltip(" · ".join(parts))

    def _handle_action(self, action: str) -> None:
        if action == "show":
            self.root.deiconify()
            self.root.lift()
        elif action == "refresh":
            self._refresh_all()
        elif action == "click_through":
            self._set_click_through(not self.settings.click_through)
        elif action == "autostart":
            self._toggle_autostart()
        elif action == "exit":
            self.exit()

    def _refresh_all(self) -> None:
        self.client.refresh()
        self.reset_client.refresh()

    def _toggle_autostart(self) -> None:
        self.settings.autostart = set_autostart(not self.settings.autostart)
        self.tray.autostart = self.settings.autostart
        self.settings.save()

    def _set_click_through(self, enabled: bool) -> None:
        try:
            import win32con
            import win32gui

            hwnd = self.root.winfo_id()
            style = win32gui.GetWindowLong(hwnd, win32con.GWL_EXSTYLE)
            if enabled:
                style |= win32con.WS_EX_LAYERED | win32con.WS_EX_TRANSPARENT
            else:
                style &= ~win32con.WS_EX_TRANSPARENT
            win32gui.SetWindowLong(hwnd, win32con.GWL_EXSTYLE, style)
            self.settings.click_through = enabled
            self.tray.click_through = enabled
            self.settings.save()
        except (ImportError, OSError):
            self.settings.click_through = False

    def _show_context_menu(self, event: tk.Event) -> None:
        menu = tk.Menu(self.root, tearoff=False)
        menu.add_command(label="立即刷新", command=self._refresh_all)
        menu.add_command(label="隐藏到托盘", command=self.root.withdraw)
        menu.add_command(
            label="关闭鼠标穿透" if self.settings.click_through else "开启鼠标穿透",
            command=lambda: self._set_click_through(not self.settings.click_through),
        )
        menu.add_command(
            label="关闭开机启动" if self.settings.autostart else "开启开机启动",
            command=self._toggle_autostart,
        )
        menu.add_separator()
        menu.add_command(label="退出", command=self.exit)
        menu.tk_popup(event.x_root, event.y_root)

    def _start_drag(self, event: tk.Event) -> None:
        self._drag_offset = (event.x_root - self.root.winfo_x(), event.y_root - self.root.winfo_y())

    def _drag(self, event: tk.Event) -> None:
        x = event.x_root - self._drag_offset[0]
        y = event.y_root - self._drag_offset[1]
        self.root.geometry(f"{signed(x)}{signed(y)}")

    def _end_drag(self, _event: tk.Event) -> None:
        self.settings.x = self.root.winfo_x()
        self.settings.y = self.root.winfo_y()
        self.settings.save()

    def exit(self) -> None:
        if self._exiting:
            return
        self._exiting = True
        self.client.stop()
        self.reset_client.stop()
        self.monitor.stop()
        self.tray.stop()
        self.settings.save()
        self.root.after(50, self.root.destroy)


def compact_window_label(minutes: int | None) -> str:
    if minutes is None or minutes == 10080:
        return "周用量"
    if minutes % 1440 == 0:
        return f"{minutes // 1440}天用量"
    if minutes % 60 == 0:
        return f"{minutes // 60}小时用量"
    return f"{minutes}分钟"


def signed(value: int) -> str:
    return f"+{value}" if value >= 0 else str(value)


def apply_rounded_corners(hwnd: int) -> None:
    try:
        preference = ctypes.c_int(2)
        ctypes.windll.dwmapi.DwmSetWindowAttribute(
            hwnd, 33, ctypes.byref(preference), ctypes.sizeof(preference)
        )
    except (AttributeError, OSError):
        pass


def enable_dpi_awareness() -> None:
    try:
        ctypes.windll.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
    except (AttributeError, OSError):
        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(2)
        except (AttributeError, OSError):
            pass


def run_app(startup: bool = False, qa_window: bool = False) -> None:
    if sys.platform != "win32":
        raise SystemExit("本程序仅支持 Windows。")
    enable_dpi_awareness()
    OverlayApp(startup=startup, qa_window=qa_window).run()
