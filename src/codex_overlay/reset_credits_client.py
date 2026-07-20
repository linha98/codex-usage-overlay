from __future__ import annotations

import json
import os
import queue
import threading
import time
from pathlib import Path
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from .models import ResetCreditsSnapshot


RESET_CREDITS_URL = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"


class ResetCreditsClient:
    """每小时静默读取一次当前账号的重置机会。"""

    def __init__(
        self,
        refresh_seconds: float = 3600.0,
        fetcher: Callable[[], ResetCreditsSnapshot] | None = None,
    ) -> None:
        self.refresh_seconds = max(1.0, refresh_seconds)
        self.events: queue.Queue[tuple[str, Any]] = queue.Queue()
        self._fetcher = fetcher or fetch_reset_credits
        self._stop = threading.Event()
        self._refresh = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="codex-reset-credits", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._refresh.set()

    def refresh(self) -> None:
        self._refresh.set()

    def _run(self) -> None:
        next_fetch = 0.0
        while not self._stop.is_set():
            now = time.monotonic()
            if now >= next_fetch or self._refresh.is_set():
                self._refresh.clear()
                try:
                    snapshot = self._fetcher()
                except Exception as exc:  # 后台失败只能转为脱敏状态，不能弹窗
                    self.events.put(("error", safe_reset_error(exc)))
                else:
                    self.events.put(("snapshot", snapshot))
                next_fetch = time.monotonic() + self.refresh_seconds

            wait_seconds = max(0.1, next_fetch - time.monotonic())
            self._refresh.wait(wait_seconds)


def auth_file_path() -> Path:
    codex_home = os.environ.get("CODEX_HOME")
    if codex_home and codex_home.strip():
        return Path(codex_home) / "auth.json"
    user_profile = os.environ.get("USERPROFILE")
    root = Path(user_profile) if user_profile else Path.home()
    return root / ".codex" / "auth.json"


def load_access_token(path: Path | None = None) -> str:
    auth_path = path or auth_file_path()
    try:
        value = json.loads(auth_path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise RuntimeError("未找到 Codex 登录信息") from exc
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError("无法读取 Codex 登录信息") from exc

    tokens = value.get("tokens") if isinstance(value, dict) else None
    token = tokens.get("access_token") if isinstance(tokens, dict) else None
    if not isinstance(token, str) or not token.strip():
        raise RuntimeError("Codex 登录信息中没有可用凭据")
    return token


def fetch_reset_credits(
    *,
    timeout: float = 20.0,
    opener: Callable[..., Any] = urlopen,
    auth_path: Path | None = None,
) -> ResetCreditsSnapshot:
    token = load_access_token(auth_path)
    request = Request(
        RESET_CREDITS_URL,
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
            "Origin": "https://chatgpt.com",
            "Referer": "https://chatgpt.com/",
        },
        method="GET",
    )
    with opener(request, timeout=timeout) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return ResetCreditsSnapshot.from_response(payload)


def safe_reset_error(exc: Exception) -> str:
    if isinstance(exc, HTTPError):
        if exc.code in (401, 403):
            return "重置次数认证已失效"
        return f"重置次数服务返回 {exc.code}"
    if isinstance(exc, (TimeoutError, URLError)):
        return "重置次数网络不可用"
    if isinstance(exc, (RuntimeError, ValueError)):
        return str(exc)[:80]
    return "重置次数暂时不可用"
