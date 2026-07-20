from __future__ import annotations

import json
import os
import queue
import shutil
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

from .models import RateLimitSnapshot


class CodexAppServerClient:
    """通过 JSONL-over-stdio 读取 Codex 账户限额。"""

    def __init__(self, refresh_seconds: float = 60.0) -> None:
        self.refresh_seconds = refresh_seconds
        self.events: queue.Queue[tuple[str, Any]] = queue.Queue()
        self._stop = threading.Event()
        self._refresh = threading.Event()
        self._write_lock = threading.Lock()
        self._pending_lock = threading.Lock()
        self._pending: dict[int, queue.Queue[dict[str, Any]]] = {}
        self._request_id = 0
        self._process: subprocess.Popen[str] | None = None
        self._snapshot: RateLimitSnapshot | None = None
        self._supervisor: threading.Thread | None = None

    def start(self) -> None:
        if self._supervisor and self._supervisor.is_alive():
            return
        self._stop.clear()
        self._supervisor = threading.Thread(target=self._run, name="codex-app-server", daemon=True)
        self._supervisor.start()

    def stop(self) -> None:
        self._stop.set()
        self._refresh.set()
        process = self._process
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()

    def refresh(self) -> None:
        self._refresh.set()

    def _run(self) -> None:
        retry_delay = 2.0
        while not self._stop.is_set():
            try:
                executable = find_codex_executable()
                if executable is None:
                    raise RuntimeError("未找到 codex.exe")
                self._serve_once(executable)
                retry_delay = 2.0
            except Exception as exc:  # 后台线程必须转为用户可读状态
                self.events.put(("connection", f"连接失败：{safe_error(exc)}"))
            finally:
                self._close_process()
            if self._stop.wait(retry_delay):
                break
            retry_delay = min(30.0, retry_delay * 2)

    def _serve_once(self, executable: Path) -> None:
        creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        self._process = subprocess.Popen(
            [str(executable), "app-server", "--listen", "stdio://"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            creationflags=creation_flags,
        )
        assert self._process.stdout is not None
        reader = threading.Thread(target=self._read_stdout, args=(self._process.stdout,), daemon=True)
        reader.start()
        assert self._process.stderr is not None
        threading.Thread(target=self._drain_stderr, args=(self._process.stderr,), daemon=True).start()

        self._request(
            "initialize",
            {
                "clientInfo": {
                    "name": "codex-usage-overlay",
                    "title": "Codex 用量悬浮窗",
                    "version": "1.0.0",
                }
            },
            timeout=12,
        )
        self._notify("initialized", {})
        self.events.put(("connection", "已连接 Codex"))
        self._fetch_limits()

        next_refresh = time.monotonic() + self.refresh_seconds
        while not self._stop.is_set():
            if self._process.poll() is not None:
                raise RuntimeError("Codex 服务已退出")
            wait_for = max(0.1, min(1.0, next_refresh - time.monotonic()))
            requested = self._refresh.wait(wait_for)
            if requested:
                self._refresh.clear()
            if requested or time.monotonic() >= next_refresh:
                self._fetch_limits()
                next_refresh = time.monotonic() + self.refresh_seconds

    def _fetch_limits(self) -> None:
        result = self._request("account/rateLimits/read", {}, timeout=15)
        self._snapshot = RateLimitSnapshot.from_response(result)
        self.events.put(("usage", self._snapshot))

    def _request(self, method: str, params: dict[str, Any], timeout: float) -> Any:
        self._request_id += 1
        request_id = self._request_id
        response_queue: queue.Queue[dict[str, Any]] = queue.Queue(maxsize=1)
        with self._pending_lock:
            self._pending[request_id] = response_queue
        try:
            self._send({"id": request_id, "method": method, "params": params})
            try:
                response = response_queue.get(timeout=timeout)
            except queue.Empty as exc:
                raise TimeoutError(f"{method} 响应超时") from exc
            if "error" in response:
                error = response.get("error")
                message = error.get("message") if isinstance(error, dict) else str(error)
                raise RuntimeError(message or f"{method} 调用失败")
            return response.get("result", {})
        finally:
            with self._pending_lock:
                self._pending.pop(request_id, None)

    def _notify(self, method: str, params: dict[str, Any]) -> None:
        self._send({"method": method, "params": params})

    def _send(self, payload: dict[str, Any]) -> None:
        process = self._process
        if process is None or process.stdin is None or process.poll() is not None:
            raise RuntimeError("Codex 服务未运行")
        line = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
        with self._write_lock:
            process.stdin.write(line + "\n")
            process.stdin.flush()

    def _read_stdout(self, stream: Any) -> None:
        for line in stream:
            if self._stop.is_set():
                return
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(message, dict):
                continue
            request_id = message.get("id")
            if isinstance(request_id, int):
                with self._pending_lock:
                    target = self._pending.get(request_id)
                if target is not None:
                    target.put(message)
                continue
            if message.get("method") == "account/rateLimits/updated":
                params = message.get("params")
                if isinstance(params, dict):
                    self._snapshot = RateLimitSnapshot.from_response(
                        params, self._snapshot, sparse=True
                    )
                    self.events.put(("usage", self._snapshot))

    def _drain_stderr(self, stream: Any) -> None:
        for _line in stream:
            if self._stop.is_set():
                return

    def _close_process(self) -> None:
        process = self._process
        self._process = None
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()


def find_codex_executable() -> Path | None:
    override = os.environ.get("CODEX_EXE")
    if override:
        path = Path(override).expanduser()
        if path.is_file():
            return path

    discovered = shutil.which("codex")
    if discovered:
        return Path(discovered)

    local_app_data = os.environ.get("LOCALAPPDATA")
    candidates: list[Path] = []
    if local_app_data:
        root = Path(local_app_data)
        candidates.extend(
            [
                root / "Programs" / "OpenAI" / "Codex" / "bin" / "codex.exe",
                root / "OpenAI" / "Codex" / "bin" / "codex.exe",
            ]
        )
        dynamic_bin = root / "OpenAI" / "Codex" / "bin"
        if dynamic_bin.is_dir():
            candidates.extend(dynamic_bin.glob("*\\codex.exe"))

    for path in candidates:
        if path.is_file():
            return path
    return None


def safe_error(exc: Exception) -> str:
    text = str(exc).strip().replace("\r", " ").replace("\n", " ")
    return text[:160] if text else exc.__class__.__name__
