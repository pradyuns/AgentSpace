import subprocess
import unittest
from pathlib import Path
try:
    from .session_test_support import SocketFixture
except ImportError:
    from session_test_support import SocketFixture

BIN = Path(__file__).resolve().parent.parent / '.build/debug/agentspace-regression'


@unittest.skipUnless(BIN.exists(), 'regression binary not built')
class SessionTransport(unittest.TestCase):
    def probe(self, mode, expected):
        with SocketFixture(mode) as fixture:
            result = subprocess.run([str(BIN), '--cdp-socket-probe', fixture.url, mode],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), expected)
            self.assertEqual(fixture.connections, 1, 'no approval reconnect is allowed')
            if mode == 'immediate':
                self.assertEqual(len(fixture.requests), 250)

    def test_immediate_receipts(self):
        self.probe('immediate', 'receipts-preserved')

    def test_immediate_disconnect(self):
        self.probe('disconnect', 'closed')

    def test_overflow_fails_instead_of_dropping_paused_requests(self):
        self.probe('overflow', 'eventOverflow')

    def test_unanswered_identification_is_unresolved_without_retry(self):
        self.probe('unresolved', 'approval_unresolved')


if __name__ == '__main__':
    unittest.main()
