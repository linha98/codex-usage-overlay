import json
import queue
import tempfile
import unittest
from pathlib import Path
from urllib.error import HTTPError, URLError

from codex_overlay.models import ResetCreditsSnapshot
from codex_overlay.reset_credits_client import (
    RESET_CREDITS_URL,
    ResetCreditsClient,
    fetch_reset_credits,
    load_access_token,
    safe_reset_error,
)


class FakeResponse:
    def __init__(self, payload: dict) -> None:
        self.payload = payload

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *_args: object) -> None:
        return None

    def read(self) -> bytes:
        return json.dumps(self.payload).encode("utf-8")


class ResetCreditsClientTests(unittest.TestCase):
    def test_fetch_uses_required_https_request_without_exposing_token(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            auth_path = Path(directory) / "auth.json"
            auth_path.write_text(
                json.dumps({"tokens": {"access_token": "test-secret"}}), encoding="utf-8"
            )
            captured = {}

            def opener(request, timeout):
                captured["url"] = request.full_url
                captured["authorization"] = request.get_header("Authorization")
                captured["origin"] = request.get_header("Origin")
                captured["timeout"] = timeout
                return FakeResponse(
                    {
                        "available_count": 1,
                        "credits": [{"expires_at": "2026-07-26T15:41:18Z"}],
                    }
                )

            snapshot = fetch_reset_credits(auth_path=auth_path, opener=opener, timeout=3)

        self.assertEqual(snapshot.available_count, 1)
        self.assertEqual(captured["url"], RESET_CREDITS_URL)
        self.assertEqual(captured["authorization"], "Bearer test-secret")
        self.assertEqual(captured["origin"], "https://chatgpt.com")
        self.assertEqual(captured["timeout"], 3)

    def test_missing_auth_and_access_token_are_reported(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "missing.json"
            with self.assertRaisesRegex(RuntimeError, "未找到"):
                load_access_token(missing)

            empty = Path(directory) / "auth.json"
            empty.write_text("{}", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "没有可用凭据"):
                load_access_token(empty)

    def test_http_and_network_errors_are_sanitized(self) -> None:
        unauthorized = HTTPError(RESET_CREDITS_URL, 401, "secret body", {}, None)
        self.assertEqual(safe_reset_error(unauthorized), "重置次数认证已失效")
        self.assertEqual(safe_reset_error(URLError("private network detail")), "重置次数网络不可用")

    def test_background_client_fetches_at_start_and_on_manual_refresh(self) -> None:
        calls = 0

        def fetcher() -> ResetCreditsSnapshot:
            nonlocal calls
            calls += 1
            return ResetCreditsSnapshot.from_response({"available_count": calls, "credits": []})

        client = ResetCreditsClient(refresh_seconds=3600, fetcher=fetcher)
        client.start()
        try:
            first_kind, first = client.events.get(timeout=2)
            client.refresh()
            second_kind, second = client.events.get(timeout=2)
        except queue.Empty as exc:
            self.fail(f"后台查询未按时完成：{exc}")
        finally:
            client.stop()

        self.assertEqual(first_kind, "snapshot")
        self.assertEqual(first.available_count, 1)
        self.assertEqual(second_kind, "snapshot")
        self.assertEqual(second.available_count, 2)


if __name__ == "__main__":
    unittest.main()
