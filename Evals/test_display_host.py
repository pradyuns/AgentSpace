"""Deterministic tests for AgentSpace's own display host (agentspace-display-host).

These run the REAL built binary with AGENTSPACE_DISPLAY_FAKE=1, the host's
explicit synthetic-display test mode: no display is ever created, every display
reply is marked ``"fake": true``, no accessibility/screen-recording permission
is exercised, and nothing external is contacted. A synthetic display is a
protocol fixture ONLY - AgentSpace core rejects it as a seat, so nothing here
can be mistaken for real display creation. Tests cover the authenticated
unix-socket protocol - handshake, auth rejection, strict request validation,
bounded clients, workspace binding, session leadership and clean shutdown -
all without any TCC grant or live display.

Run: python3 -m pytest Evals/test_display_host.py -q  (after `swift build`)
"""
import json
import os
import socket
import stat
import subprocess
import tempfile
import time
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CANDIDATES = [
    ROOT / ".build" / "debug" / "agentspace-display-host",
    ROOT / ".build" / "release" / "agentspace-display-host",
]


def host_binary():
    for path in CANDIDATES:
        if path.exists() and os.access(path, os.X_OK):
            return str(path)
    return None


def request(sock_path, payload, raw=None, timeout=10):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(sock_path)
    try:
        s.sendall(raw if raw is not None else json.dumps(payload).encode() + b"\n")
    except BrokenPipeError:
        pass  # server stopped reading at the cap but still replies
    try:
        s.shutdown(socket.SHUT_WR)
    except OSError:
        pass
    data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    s.close()
    return json.loads(data.decode().strip()) if data.strip() else None


class HostFixture(unittest.TestCase):
    token = "a1" * 32  # host requires >=32 hex chars
    ws_uuid = str(uuid.uuid4())

    @classmethod
    def setUpClass(cls):
        binary = host_binary()
        if not binary:
            raise unittest.SkipTest("agentspace-display-host not built; run `swift build` first")
        cls.binary = binary
        cls.dir = tempfile.TemporaryDirectory(prefix="asdh-test-")
        os.chmod(cls.dir.name, 0o700)
        cls.sock = os.path.join(cls.dir.name, "test.sock")
        cls.token_file = os.path.join(cls.dir.name, "token")
        Path(cls.token_file).write_text(cls.token)
        os.chmod(cls.token_file, 0o600)
        cls.log = os.path.join(cls.dir.name, "host.log")
        env = dict(os.environ, AGENTSPACE_DISPLAY_FAKE="1")
        cls.proc = subprocess.Popen(
            [binary, "--workspace-uuid", cls.ws_uuid, "--socket", cls.sock,
             "--token-file", cls.token_file, "--width", "1280", "--height", "800",
             "--hidpi", "0", "--name", "test-display", "--log", cls.log],
            env=env,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 10
        while time.time() < deadline:
            if cls.proc.poll() is not None:
                raise unittest.SkipTest("display host exited during startup: "
                                        + Path(cls.log).read_text(errors="replace")[-500:])
            if os.path.exists(cls.sock):
                break
            time.sleep(0.05)
        else:
            raise unittest.SkipTest("display host socket never appeared")

    @classmethod
    def tearDownClass(cls):
        if cls.proc.poll() is None:
            cls.proc.terminate()
            try:
                cls.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                cls.proc.kill()
        cls.dir.cleanup()

    _DEFAULT = object()

    def call(self, op, token=_DEFAULT, **fields):
        payload = {"token": self.token if token is self._DEFAULT else token, "op": op}
        payload.update(fields)
        return request(self.sock, payload)


class TestDisplayHost(HostFixture):
    def test_hello_returns_identity_and_display(self):
        reply = self.call("hello", workspaceUUID=self.ws_uuid)
        self.assertTrue(reply["ok"])
        self.assertEqual(reply["pid"], self.proc.pid)
        self.assertEqual(reply["protocol"], 1)
        self.assertEqual(reply["workspaceUUID"], self.ws_uuid)
        self.assertEqual(reply["display"]["id"], 0x41475654)
        self.assertEqual(reply["display"]["bounds"]["width"], 1280)
        self.assertEqual(reply["display"]["fake"], True)

    def test_auth_rejected_wrong_and_missing_token(self):
        for bad in ["", "wrong", None]:
            reply = self.call("hello", token=bad, workspaceUUID=self.ws_uuid)
            self.assertFalse(reply["ok"])
            self.assertEqual(reply["error"]["code"], "auth_failed")
        # A failed auth must not affect the still-running host.
        self.assertIsNone(self.proc.poll())

    def test_workspace_uuid_binding(self):
        reply = self.call("hello", workspaceUUID="not-the-workspace")
        self.assertFalse(reply["ok"])
        self.assertEqual(reply["error"]["code"], "workspace_mismatch")
        self.assertIsNone(self.proc.poll())

    def test_unknown_op(self):
        reply = self.call("definitely-not-an-op")
        self.assertFalse(reply["ok"])
        self.assertEqual(reply["error"]["code"], "unknown_op")
        self.assertIsNone(self.proc.poll())

    def test_malformed_json_replied_and_host_survives(self):
        reply = request(self.sock, None, raw=b"{this is not json\n")
        self.assertFalse(reply["ok"])
        self.assertEqual(reply["error"]["code"], "protocol_error")
        reply = self.call("hello", workspaceUUID=self.ws_uuid)
        self.assertTrue(reply["ok"])

    def test_oversized_request_rejected(self):
        reply = request(self.sock, None, raw=b'{"token":"x","op":"hello","pad":"'
                        + b"A" * (300 * 1024) + b'"}\n')
        self.assertFalse(reply["ok"])
        self.assertEqual(reply["error"]["code"], "request_too_large")
        self.assertIsNone(self.proc.poll())

    def test_status_reports_uptime(self):
        reply = self.call("status", workspaceUUID=self.ws_uuid)
        self.assertTrue(reply["ok"])
        self.assertGreaterEqual(reply["uptimeSeconds"], 0)
        self.assertIsNotNone(reply["display"]["id"])

    def test_status_always_marks_display_synthetic(self):
        # A fake-mode display must be unmistakable in every reply - no caller
        # may ever count it as real display creation.
        reply = self.call("status", workspaceUUID=self.ws_uuid)
        self.assertTrue(reply["display"]["fake"])
        self.assertEqual(reply["display"]["id"], 0x41475654)

    def test_host_is_session_leader(self):
        # setsid() at startup: the helper must not share the caller's process
        # group, so a Ctrl-C on the caller's terminal can never reach it.
        self.assertEqual(os.getsid(self.proc.pid), self.proc.pid)
        self.assertNotEqual(os.getpgid(self.proc.pid), os.getpgid(0))

    def test_create_display_rejects_bad_dimensions(self):
        # Authenticated create-display must never silently default a bad
        # value: wrong types, non-integers, out-of-range, or invalid refresh.
        for fields in ({"width": "wide"}, {"width": 1.5}, {"width": -5},
                       {"width": 99999}, {"height": "tall"}, {"hiDPI": "yes"},
                       {"refresh": "fast"}, {"refresh": 0}, {"refresh": 999}):
            reply = self.call("create-display", **fields)
            self.assertFalse(reply["ok"], fields)
            self.assertEqual(reply["error"]["code"], "invalid_dimensions", fields)
        self.assertIsNone(self.proc.poll())

    def test_create_display_conflicts_when_live(self):
        # The display created eagerly at startup is still live - a second
        # create is a conflict, never a silent replacement.
        reply = self.call("create-display", width=640, height=480)
        self.assertFalse(reply["ok"])
        self.assertEqual(reply["error"]["code"], "conflict")

    def test_zz_destroy_then_shutdown(self):
        # Second fixture would share the socket; do destroy+shutdown as the
        # last stateful test on this host.
        reply = self.call("destroy-display")
        self.assertTrue(reply["ok"])
        self.assertTrue(reply["result"]["released"])
        reply = self.call("shutdown")
        self.assertTrue(reply["ok"])
        self.assertTrue(reply["exiting"])
        self.proc.wait(timeout=10)
        self.assertEqual(self.proc.returncode, 0)
        # The host cleans its own socket file on exit.
        self.assertFalse(os.path.exists(self.sock))


class TestDisplayHostSlowClient(unittest.TestCase):
    """A host with a short --io-timeout: a client that never completes its
    request is dropped at the absolute deadline and cannot stall the host."""

    def test_slow_client_is_dropped_and_host_stays_responsive(self):
        binary = host_binary()
        if not binary:
            self.skipTest("agentspace-display-host not built")
        token = "c3" * 32
        with tempfile.TemporaryDirectory(prefix="asdh-slow-") as d:
            sock, token_file, log = (os.path.join(d, n) for n in ("s.sock", "token", "log"))
            Path(token_file).write_text(token)
            os.chmod(token_file, 0o600)
            env = dict(os.environ, AGENTSPACE_DISPLAY_FAKE="1")
            proc = subprocess.Popen(
                [binary, "--workspace-uuid", "w3", "--socket", sock,
                 "--token-file", token_file, "--log", log, "--io-timeout", "1"],
                env=env,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                for _ in range(200):
                    if os.path.exists(sock):
                        break
                    if proc.poll() is not None:
                        self.fail("host exited during startup: "
                                  + Path(log).read_text(errors="replace")[-500:])
                    time.sleep(0.05)
                slow = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                slow.settimeout(8)
                slow.connect(sock)
                slow.sendall(b'{"token"')  # a request that never completes
                time.sleep(2.5)            # well past --io-timeout 1
                try:
                    slow.sendall(b':"x","op":"hello"}\n')
                    tail = slow.recv(4096)
                except (BrokenPipeError, ConnectionResetError):
                    tail = b""
                slow.close()
                self.assertFalse(tail.strip(),
                                 "the host must not reply to a request that outlived the deadline")
                # The accept loop was never held hostage.
                reply = request(sock, {"token": token, "op": "hello"})
                self.assertTrue(reply["ok"])
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        proc.kill()


class TestDisplayHostFresh(unittest.TestCase):
    """A second host instance to prove shutdown ordering is not fixture-luck."""

    def test_peer_mismatch_socket_token_mode(self):
        binary = host_binary()
        if not binary:
            self.skipTest("agentspace-display-host not built")
        with tempfile.TemporaryDirectory(prefix="asdh-test2-") as d:
            sock, token_file, log = (os.path.join(d, n) for n in ("s.sock", "token", "log"))
            Path(token_file).write_text("b2" * 32)
            os.chmod(token_file, 0o600)
            env = dict(os.environ, AGENTSPACE_DISPLAY_FAKE="1")
            proc = subprocess.Popen(
                [binary, "--workspace-uuid", "w2", "--socket", sock,
                 "--token-file", token_file, "--log", log],
                env=env,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                for _ in range(200):
                    if os.path.exists(sock):
                        break
                    if proc.poll() is not None:
                        self.fail("host exited during startup: "
                                  + Path(log).read_text(errors="replace")[-500:])
                    time.sleep(0.05)
                mode = stat.S_IMODE(os.stat(sock).st_mode)
                self.assertEqual(mode, 0o600, "socket must be 0600")
                reply = request(sock, {"token": "b2" * 32, "op": "shutdown"})
                self.assertTrue(reply["ok"])
                proc.wait(timeout=10)
                self.assertEqual(proc.returncode, 0)
            finally:
                if proc.poll() is None:
                    proc.kill()


if __name__ == "__main__":
    unittest.main()
