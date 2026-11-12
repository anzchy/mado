"""PROBE for #613 §6: an injected device-tool test failure must fail Agent tooling. Never merge."""
import unittest


class InjectedFailureProbe(unittest.TestCase):
    def test_injected_failure_fails_agent_tooling(self):
        self.assertEqual(1, 2, "probe-613: injected device-tool test failure")


if __name__ == "__main__":
    unittest.main()
