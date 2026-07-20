from __future__ import annotations

import os
import queue
import re
import threading
import time
from dataclasses import dataclass
from pathlib import Path


EVENT_PATTERN = re.compile(
    br'"type"\s*:\s*"event_msg"\s*,\s*"payload"\s*:\s*\{[^{}\r\n]{0,512}?'
    br'"type"\s*:\s*"(task_started|task_complete|turn_aborted)"'
)


@dataclass(frozen=True)
class ActivitySnapshot:
    status: str
    active_count: int
    detail: str


@dataclass
class _FileState:
    offset: int = 0
    active: bool = False
    modified_at: float = 0.0


def apply_session_bytes(active: bool, data: bytes) -> bool:
    for match in EVENT_PATTERN.finditer(data):
        event = match.group(1)
        if event == b"task_started":
            active = True
        elif event in (b"task_complete", b"turn_aborted"):
            active = False
    return active


class SessionActivityMonitor:
    """只识别 session JSONL 中的任务生命周期类型，不解析任务正文。"""

    def __init__(self, poll_seconds: float = 1.0, stale_hours: float = 12.0) -> None:
        self.poll_seconds = poll_seconds
        self.stale_seconds = stale_hours * 3600
        self.events: queue.Queue[ActivitySnapshot] = queue.Queue()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._states: dict[Path, _FileState] = {}
        self._last_snapshot: ActivitySnapshot | None = None
        self.sessions_dir = codex_home() / "sessions"

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="codex-session-monitor", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def scan_once(self) -> ActivitySnapshot:
        if not self.sessions_dir.is_dir():
            return ActivitySnapshot("unknown", 0, "未找到 Codex sessions 目录")

        try:
            files = sorted(
                self.sessions_dir.rglob("*.jsonl"),
                key=lambda path: path.stat().st_mtime,
                reverse=True,
            )[:60]
        except OSError:
            return ActivitySnapshot("unknown", 0, "无法读取 Codex sessions 目录")

        now = time.time()
        for path in files:
            self._update_file(path)

        active_states = [state for state in self._states.values() if state.active]
        fresh_active = [
            state for state in active_states if now - state.modified_at <= self.stale_seconds
        ]
        if fresh_active:
            return ActivitySnapshot("running", len(fresh_active), "检测到未完成任务")
        if active_states:
            return ActivitySnapshot("unknown", 0, "存在长时间未结束的任务记录")
        return ActivitySnapshot("idle", 0, "当前没有执行中的任务")

    def _run(self) -> None:
        while not self._stop.is_set():
            snapshot = self.scan_once()
            if snapshot != self._last_snapshot:
                self._last_snapshot = snapshot
                self.events.put(snapshot)
            self._stop.wait(self.poll_seconds)

    def _update_file(self, path: Path) -> None:
        state = self._states.setdefault(path, _FileState())
        try:
            stat = path.stat()
            if stat.st_size < state.offset:
                state.offset = 0
                state.active = False
            if stat.st_size > state.offset:
                with path.open("rb") as stream:
                    stream.seek(state.offset)
                    data = stream.read()
                    state.offset = stream.tell()
                state.active = apply_session_bytes(state.active, data)
            state.modified_at = stat.st_mtime
        except (OSError, ValueError):
            return


def codex_home() -> Path:
    configured = os.environ.get("CODEX_HOME")
    if configured:
        return Path(configured).expanduser()
    return Path.home() / ".codex"
