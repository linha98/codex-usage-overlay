from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal
from datetime import datetime, timedelta, timezone
from typing import Any


CHINA_TIMEZONE = timezone(timedelta(hours=8), name="UTC+8")


@dataclass(frozen=True)
class LimitWindow:
    used_percent: int | float
    window_duration_mins: int | None
    resets_at: float | None

    @classmethod
    def from_dict(cls, value: Any) -> "LimitWindow | None":
        if not isinstance(value, dict):
            return None
        used = value.get("usedPercent")
        if not isinstance(used, (int, float)):
            return None
        duration = value.get("windowDurationMins")
        reset = value.get("resetsAt")
        return cls(
            used_percent=max(0, min(100, used)),
            window_duration_mins=int(duration) if isinstance(duration, (int, float)) else None,
            resets_at=float(reset) if isinstance(reset, (int, float)) else None,
        )


def format_used_percent(value: int | float) -> str:
    """按接口数值精度显示用量，最多保留两位小数。"""
    if isinstance(value, int):
        return f"{value}%"
    decimal_value = Decimal(str(value))
    decimal_places = min(2, max(0, -decimal_value.as_tuple().exponent))
    quantum = Decimal(1).scaleb(-decimal_places)
    rounded = decimal_value.quantize(quantum, rounding=ROUND_HALF_UP)
    return f"{rounded:.{decimal_places}f}%"


@dataclass(frozen=True)
class RateLimitSnapshot:
    primary: LimitWindow | None
    secondary: LimitWindow | None
    plan_type: str | None
    credits_balance: str | float | int | None
    spend_control_reached: bool | None
    raw: dict[str, Any]

    @classmethod
    def from_response(
        cls,
        value: Any,
        previous: "RateLimitSnapshot | None" = None,
        *,
        sparse: bool = False,
    ) -> "RateLimitSnapshot":
        incoming = value if isinstance(value, dict) else {}
        if sparse and previous is not None:
            raw = merge_sparse(previous.raw, incoming)
        else:
            raw = deepcopy(incoming)

        limits = raw.get("rateLimits")
        if not isinstance(limits, dict):
            limits = raw

        credits = raw.get("credits")
        if not isinstance(credits, dict):
            credits = limits.get("credits") if isinstance(limits.get("credits"), dict) else {}

        plan_type = raw.get("planType") or limits.get("planType")
        spend_control = raw.get("spendControlReached")
        if spend_control is None:
            spend_control = limits.get("spendControlReached")

        return cls(
            primary=LimitWindow.from_dict(limits.get("primary")),
            secondary=LimitWindow.from_dict(limits.get("secondary")),
            plan_type=str(plan_type) if plan_type is not None else None,
            credits_balance=credits.get("balance"),
            spend_control_reached=spend_control if isinstance(spend_control, bool) else None,
            raw=raw,
        )


@dataclass(frozen=True)
class ResetCreditsSnapshot:
    available_count: int
    expires_at_utc: tuple[datetime, ...]
    fetched_at_utc: datetime

    @property
    def nearest_expiry_utc(self) -> datetime | None:
        if self.available_count <= 0:
            return None
        return min(self.expires_at_utc, default=None)

    @classmethod
    def from_response(
        cls,
        value: Any,
        *,
        fetched_at_utc: datetime | None = None,
    ) -> "ResetCreditsSnapshot":
        if not isinstance(value, dict):
            raise ValueError("重置次数接口返回了无效数据")

        available_count = value.get("available_count")
        if isinstance(available_count, bool) or not isinstance(available_count, int):
            raise ValueError("重置次数接口未返回有效次数")

        credits = value.get("credits", [])
        if not isinstance(credits, list):
            raise ValueError("重置次数接口未返回有效到期列表")

        expiries: list[datetime] = []
        for credit in credits:
            if not isinstance(credit, dict):
                raise ValueError("重置次数接口返回了无效到期记录")
            expiries.append(parse_utc_datetime(credit.get("expires_at")))

        fetched = fetched_at_utc or datetime.now(timezone.utc)
        if fetched.tzinfo is None:
            fetched = fetched.replace(tzinfo=timezone.utc)

        return cls(
            available_count=max(0, available_count),
            expires_at_utc=tuple(sorted(expiries)),
            fetched_at_utc=fetched.astimezone(timezone.utc),
        )


def parse_utc_datetime(value: Any) -> datetime:
    if not isinstance(value, str) or not value.strip():
        raise ValueError("重置次数接口缺少到期时间")
    normalized = value.strip()
    if normalized.endswith("Z"):
        normalized = normalized[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as exc:
        raise ValueError("重置次数接口返回了无效到期时间") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def format_expiry_china(value: datetime | None) -> str:
    if value is None:
        return "--"
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    china = value.astimezone(CHINA_TIMEZONE)
    return f"{china.month}/{china.day} {china:%H:%M} +8"


def merge_sparse(base: dict[str, Any], patch: dict[str, Any]) -> dict[str, Any]:
    """合并 app-server 的稀疏更新；更新中的 null 不清除已有账户数据。"""
    result = deepcopy(base)
    for key, value in patch.items():
        if value is None:
            continue
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merge_sparse(result[key], value)
        else:
            result[key] = deepcopy(value)
    return result
