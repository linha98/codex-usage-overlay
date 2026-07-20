import unittest
from datetime import datetime, timezone

from codex_overlay.models import (
    RateLimitSnapshot,
    ResetCreditsSnapshot,
    format_expiry_china,
    format_used_percent,
    merge_sparse,
)


class RateLimitSnapshotTests(unittest.TestCase):
    def test_parses_primary_and_secondary_windows(self) -> None:
        snapshot = RateLimitSnapshot.from_response(
            {
                "rateLimits": {
                    "primary": {"usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1000},
                    "secondary": {"usedPercent": 60, "windowDurationMins": 10080, "resetsAt": 2000},
                },
                "planType": "plus",
            }
        )
        self.assertEqual(snapshot.primary.used_percent, 25)
        self.assertEqual(snapshot.secondary.window_duration_mins, 10080)
        self.assertEqual(snapshot.plan_type, "plus")

    def test_sparse_null_does_not_clear_existing_data(self) -> None:
        merged = merge_sparse(
            {"rateLimits": {"primary": {"usedPercent": 25, "resetsAt": 1000}}},
            {"rateLimits": {"primary": {"usedPercent": 30, "resetsAt": None}}},
        )
        self.assertEqual(merged["rateLimits"]["primary"]["usedPercent"], 30)
        self.assertEqual(merged["rateLimits"]["primary"]["resetsAt"], 1000)

    def test_used_percent_keeps_source_precision_up_to_two_decimals(self) -> None:
        cases = (
            (11, "11%"),
            (11.2, "11.2%"),
            (11.25, "11.25%"),
            (11.245, "11.25%"),
            (11.256, "11.26%"),
        )
        for raw, expected in cases:
            with self.subTest(raw=raw):
                snapshot = RateLimitSnapshot.from_response(
                    {"rateLimits": {"primary": {"usedPercent": raw}}}
                )
                self.assertEqual(format_used_percent(snapshot.primary.used_percent), expected)


class ResetCreditsSnapshotTests(unittest.TestCase):
    def test_count_comes_from_available_count_and_nearest_is_earliest(self) -> None:
        snapshot = ResetCreditsSnapshot.from_response(
            {
                "available_count": 7,
                "credits": [
                    {"expires_at": "2026-07-31T11:53:19Z"},
                    {"expires_at": "2026-07-26T15:41:18+00:00"},
                ],
            },
            fetched_at_utc=datetime(2026, 7, 20, tzinfo=timezone.utc),
        )
        self.assertEqual(snapshot.available_count, 7)
        self.assertEqual(len(snapshot.expires_at_utc), 2)
        self.assertEqual(snapshot.nearest_expiry_utc.day, 26)

    def test_zero_credits_has_no_nearest_expiry(self) -> None:
        snapshot = ResetCreditsSnapshot.from_response(
            {
                "available_count": 0,
                "credits": [{"expires_at": "2026-07-26T15:41:18Z"}],
            }
        )
        self.assertEqual(snapshot.available_count, 0)
        self.assertIsNone(snapshot.nearest_expiry_utc)

    def test_expiry_is_formatted_in_utc_plus_eight_across_month(self) -> None:
        value = datetime(2026, 7, 31, 20, 30, tzinfo=timezone.utc)
        self.assertEqual(format_expiry_china(value), "8/1 04:30 +8")

    def test_invalid_expiry_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "无效到期时间"):
            ResetCreditsSnapshot.from_response(
                {"available_count": 1, "credits": [{"expires_at": "not-a-time"}]}
            )


if __name__ == "__main__":
    unittest.main()
