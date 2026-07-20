import unittest

from codex_overlay.session_monitor import apply_session_bytes


class SessionMonitorTests(unittest.TestCase):
    def test_task_lifecycle(self) -> None:
        started = b'{"type":"event_msg","payload":{"type":"task_started","turn_id":"1"}}\n'
        completed = b'{"type":"event_msg","payload":{"type":"task_complete","turn_id":"1"}}\n'
        self.assertTrue(apply_session_bytes(False, started))
        self.assertFalse(apply_session_bytes(True, completed))

    def test_prompt_text_does_not_trigger_lifecycle(self) -> None:
        prompt = b'{"type":"response_item","payload":{"text":"\\\"type\\\":\\\"task_started\\\""}}\n'
        self.assertFalse(apply_session_bytes(False, prompt))

    def test_abort_clears_running_state(self) -> None:
        aborted = b'{"type":"event_msg","payload":{"type":"turn_aborted"}}\n'
        self.assertFalse(apply_session_bytes(True, aborted))


if __name__ == "__main__":
    unittest.main()
