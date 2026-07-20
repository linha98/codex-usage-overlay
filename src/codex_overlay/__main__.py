from __future__ import annotations

import argparse
import json
import queue
import time

from .codex_client import CodexAppServerClient


def main() -> None:
    parser = argparse.ArgumentParser(description="Codex 用量与任务状态悬浮窗")
    parser.add_argument("--startup", action="store_true", help="由 Windows 开机启动")
    parser.add_argument("--probe", action="store_true", help="只验证 Codex 用量接口")
    parser.add_argument("--qa-window", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.probe:
        run_probe()
        return
    from .app import run_app

    run_app(startup=args.startup, qa_window=args.qa_window)


def run_probe() -> None:
    client = CodexAppServerClient(refresh_seconds=3600)
    client.start()
    deadline = time.monotonic() + 20
    try:
        while time.monotonic() < deadline:
            try:
                kind, value = client.events.get(timeout=1)
            except queue.Empty:
                continue
            if kind == "connection":
                print(json.dumps({"connection": value}, ensure_ascii=False))
            elif kind == "usage":
                result = {
                    "primary": value.primary.__dict__ if value.primary else None,
                    "secondary": value.secondary.__dict__ if value.secondary else None,
                    "plan_type": value.plan_type,
                    "has_credits_balance": value.credits_balance is not None,
                    "spend_control_reached": value.spend_control_reached,
                }
                print(json.dumps(result, ensure_ascii=False))
                return
        raise SystemExit("20 秒内没有取得用量数据")
    finally:
        client.stop()


if __name__ == "__main__":
    main()
