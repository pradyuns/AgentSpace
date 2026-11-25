import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
try:
    from .session_test_support import CDP, CDPProxy, endpoint, targets
except ImportError:
    from session_test_support import CDP, CDPProxy, endpoint, targets

REPO = Path(__file__).resolve().parent.parent
BIN_DIR = REPO / ".build" / "debug"
CHROME = Path(os.environ.get(
    "AGENTSPACE_TEST_CHROME",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"))
FIXTURES = REPO / "Fixtures"


def free_port():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


class FixtureHTTPServer:

    def __init__(self, root):
        handler = self._handler(root)
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @staticmethod
    def _handler(root):
        class Handler(http.server.SimpleHTTPRequestHandler):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory=str(root), **kwargs)

            def do_GET(self):
                route = self.path.split("?", 1)[0]
                if route == "/session-start":
                    body = b'<a href="/session-set">Sign in fixture</a>'
                elif route in ("/session-set", "/session-short-set"):
                    self.send_response(302)
                    age = 1 if route == "/session-short-set" else 3600
                    self.send_header("Set-Cookie", f"fixture_session=active; Path=/; Max-Age={age}; HttpOnly; SameSite=Lax")
                    self.send_header("Location", "/session-protected")
                    self.end_headers()
                    return
                elif route == "/session-protected":
                    signed_in = "fixture_session=active" in self.headers.get("Cookie", "")
                    name = "session-app.html" if signed_in else "session-login.html"
                    body = (Path(root) / name).read_bytes()
                elif route == "/session-expire":
                    self.send_response(302)
                    self.send_header("Set-Cookie", "fixture_session=; Path=/; Max-Age=0; HttpOnly")
                    self.send_header("Location", "/session-protected")
                    self.end_headers()
                    return
                elif route == "/expiry-first":
                    body = (Path(root) / "session-app.html").read_bytes().replace(
                        b"</body>", b"<script>setTimeout(()=>location.href='/session-login.html',1500)</script></body>")
                elif route == "/unsafe-controls":
                    body = b'''<body data-fixture-auth="signed-in" data-fixture-account="alice@fixture.io">
                        <base target="_blank"><a href="session-app.html">Base target link</a>
                        <form action="session-app.html" target="_blank"><button>Blank form</button></form>
                        <form action="session-app.html"><button formtarget="_blank">Blank submitter</button></form>
                        <button onclick="const f=document.createElement('form');f.target='_blank';f.action='session-app.html';document.body.append(f);f.submit()">Script form</button>
                        <a href="/plain-file" download="anchor-proof.bin">Plain download</a>
                        <a href="data:application/octet-stream,DATA_DOWNLOAD_PROOF" download="data-proof.bin">Data download</a>
                        <a id="blob" download="blob-proof.bin">Blob download</a>
                        <script>blob.href=URL.createObjectURL(new Blob(['BLOB_DOWNLOAD_PROOF'],{type:'application/octet-stream'}))</script>
                        <button onclick="const a=document.createElement('a');a.download='script-proof.bin';a.href='data:application/octet-stream,SCRIPT_DOWNLOAD';a.click()">Script download</button>
                        <a href="/plain-file">MIME download</a>
                        <a href="/attached-file">Header download</a>
                        </body>'''
                elif route in ("/plain-file", "/attached-file"):
                    body = b"FIXTURE_DOWNLOAD_PROOF"
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    if route == "/attached-file":
                        self.send_header("Content-Disposition", 'attachment; filename="human-proof.bin"')
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                elif route == "/popup-login":
                    body = b'''<button onclick="window.open('/session-set','login')">Popup sign in</button>
                        <a href="/attached-file">Human download</a><p>Human handoff page</p>'''
                elif route == "/gmail-probe":
                    body = b'''<div role="main"><div role="grid"></div><header id="gb" role="banner"><a aria-label="Google Account: bob@fixture.io"></a></header></div>
                        <header id="gb" role="banner"><button aria-label="Google apps">Apps</button>
                        <a aria-label="Compte Google : Alice (alice@fixture.io)" href="https://accounts.google.com/SignOutOptions?authuser=2">Account</a></header>'''
                elif route == "/restore-target":
                    body = b'''<a href="/session-app.html" target="_blank" onclick="event.preventDefault()">Retained target</a>'''
                elif route == "/frame-child":
                    body = b'''<form action="session-app.html" target="_blank"><button>Frame form</button></form>
                        <script>addEventListener('message',e=>{if(e.data==='form')document.forms[0].submit();if(e.data==='popup')window.open('session-app.html');if(e.data==='download')location.href='/attached-file'})</script>'''
                elif route == "/frame-controls":
                    origin = self.headers.get("Host", "").replace("127.0.0.1", "localhost")
                    body = ('''<body data-fixture-auth="signed-in" data-fixture-account="alice@fixture.io">
                        <iframe id="local" src="/frame-child"></iframe>
                        <iframe id="cross" src="http://ORIGIN/frame-child"></iframe>
                        <button onclick="document.getElementById('local').contentWindow.open('session-app.html')">Local frame popup</button>
                        <button onclick="document.getElementById('local').contentDocument.forms[0].submit()">Local frame form</button>
                        <button onclick="document.getElementById('cross').contentWindow.postMessage('form','*')">Cross frame form</button>
                        <button onclick="document.getElementById('cross').contentWindow.postMessage('popup','*')">Cross frame popup</button>
                        <button onclick="document.getElementById('cross').contentWindow.postMessage('download','*')">Cross frame download</button>
                        </body>'''.replace("ORIGIN", origin)).encode()
                elif route == "/control":
                    body = b'''<style>body{height:4000px}</style><input id="human" aria-label="Human control"><p>Human control page</p>'''
                elif route == "/account-switch":
                    body = (Path(root) / "session-app.html").read_bytes().replace(
                        b"</body>", b'<a href="/account-second">Switch account</a></body>')
                elif route == "/account-first":
                    body = (Path(root) / "session-app.html").read_bytes().replace(
                        b"</body>", b"<script>setTimeout(()=>location.href='/account-second',1500)</script></body>")
                elif route == "/account-second":
                    body = (Path(root) / "session-app.html").read_bytes().replace(
                        b"alice@fixture.io", b"bob@fixture.io").replace(
                        b"AgentSpace session app", b"Bob private mailbox")
                else:
                    return super().do_GET()
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def end_headers(self):
                if self.path.endswith(".bin"):
                    self.send_header("Content-Disposition", 'attachment; filename="session-download.bin"')
                super().end_headers()

            def log_message(self, *args):
                pass
        return Handler

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.server.shutdown()
        self.server.server_close()


class FixtureChrome:

    def __init__(self, root, headed=False):
        self.root = root
        args = [str(CHROME), "--remote-debugging-port=0",
                "--remote-debugging-address=127.0.0.1",
                "--no-first-run", "--no-default-browser-check",
                "--disable-component-update", "--disable-sync",
                f"--user-data-dir={root}", "about:blank"]
        if not headed:
            args.insert(1, "--headless=new")
        self.process = subprocess.Popen(args, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL)

    def wait_ready(self, timeout=30):
        port_file = self.root / "DevToolsActivePort"
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError("fixture Chrome exited during startup")
            if port_file.exists():
                lines = port_file.read_text().splitlines()
                if len(lines) >= 2 and lines[0].strip().isdigit():
                    return
            time.sleep(0.1)
        raise RuntimeError("fixture Chrome never published DevToolsActivePort")

    def alive(self):
        return self.process.poll() is None

    def stop(self):
        if self.alive():
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()


class AgentSpaceCLI:

    def __init__(self, state, chrome_root):
        self.env = dict(os.environ)
        self.env["AGENTSPACE_HOME"] = str(state)
        self.env["AGENTSPACE_CHROME_USER_DIR"] = str(chrome_root)
        self.env["AGENTSPACE_SESSION_BROKER"] = str(BIN_DIR / "agentspace-session-broker")
        self.state = Path(state)

    def run(self, command, workspace, **options):
        args = [str(BIN_DIR / "agentspace"), command, "--workspace", workspace]
        for key, value in options.items():
            args.append(f"--{key}")
            if value is not True:
                args.append(str(value))
        proc = subprocess.run(args, env=self.env, capture_output=True, text=True, timeout=120)
        return proc

    def json(self, command, workspace, **options):
        proc = self.run(command, workspace, **options)
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError:
            raise AssertionError(
                f"{command} did not emit JSON: {proc.stdout!r} stderr={proc.stderr!r}")

    def mcp(self, calls, workspace="mcp"):
        proc = subprocess.Popen([str(BIN_DIR / "agentspace"), "mcp"], env=self.env,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True)
        replies = []

        def send(request):
            proc.stdin.write(json.dumps(request) + "\n")
            proc.stdin.flush()
            line = proc.stdout.readline()
            if not line:
                raise RuntimeError("mcp server closed stdout")
            replies.append(json.loads(line))
            return replies[-1]

        try:
            send({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {}})
            send({"jsonrpc": "2.0", "id": 99, "method": "tools/list", "params": {}})
            for index, (name, arguments) in enumerate(calls, start=1):
                send({"jsonrpc": "2.0", "id": index, "method": "tools/call",
                      "params": {"name": name, "arguments": {"workspace": workspace, **arguments}}})
        finally:
            proc.kill()
            proc.wait(timeout=5)
            proc.stdin.close()
            proc.stdout.close()
        tool_reply = replies[1]["result"]["tools"]
        tool_names = sorted(t["name"] for t in tool_reply)
        outputs = []
        for reply in replies[2:]:
            content = reply["result"]["content"]
            outputs.append((json.loads(content[0]["text"]), reply["result"].get("isError")))
        return tool_names, outputs

    def broker_dirs(self):
        root = self.state / "session-brokers"
        return sorted(root.iterdir()) if root.exists() else []

    def journal(self):
        dirs = self.broker_dirs()
        if len(dirs) != 1:
            raise AssertionError(f"expected exactly one broker dir, got {dirs}")
        return json.loads((dirs[0] / "journal.json").read_text())

    def session_log_text(self):
        dirs = self.broker_dirs()
        if not dirs:
            return ""
        path = dirs[0] / "session-log.jsonl"
        return path.read_text() if path.exists() else ""


@unittest.skipUnless(CHROME.exists(), "no Chrome binary for the fixture")
@unittest.skipUnless((BIN_DIR / "agentspace").exists(), "agentspace not built")
@unittest.skipUnless((BIN_DIR / "agentspace-session-broker").exists(), "broker not built")
class ChromeSessionSmoke(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="as-session-"))
        self.chrome_root = self.tmp / "chrome"
        self.state = self.tmp / "state"
        self.chrome = FixtureChrome(self.chrome_root)
        self.chrome.wait_ready()
        self.cli = AgentSpaceCLI(self.state, self.chrome_root)

    def tearDown(self):
        self.chrome.stop()
        for directory in (self.state / "session-brokers").glob("*"):
            record = directory / "broker.json"
            if record.exists():
                try:
                    pid = json.loads(record.read_text())["pid"]
                    subprocess.run(["kill", str(pid)], capture_output=True, timeout=5)
                except Exception:
                    pass
        shutil.rmtree(self.tmp, ignore_errors=True)

    def http_url(self, server, name):
        return f"http://127.0.0.1:{server.port}/{name}"

    @staticmethod
    def payload(reply):
        return reply.get("result") or reply

    def test_shared_session_cli_lifecycle(self):
        cli = self.cli
        with FixtureHTTPServer(FIXTURES) as http:
            url = self.http_url(http, "session-app.html")
            proc = cli.run("create-workspace", "smoke", backend="cdp")
            self.assertEqual(proc.returncode, 0, proc.stderr)

            launched = cli.json("launch-app", "smoke", app="chrome",
                                **{"chrome-session": "existing", "url": url,
                                   "site": "fixture", "expected-account": "alice@fixture.io"})
            self.assertTrue(launched.get("ok"), launched)
            opened = self.payload(launched)
            self.assertEqual(opened.get("access", {}).get("access"), "accessible", launched)
            self.assertEqual(opened.get("access", {}).get("identity"), "verified", launched)
            self.assertEqual(opened.get("session", {}).get("access", {}).get("identityMethod"),
                             "fixture-account-readback", launched)

            observed = cli.json("observe", "smoke")
            self.assertTrue(observed.get("ok"), observed)
            self.assertIn("Session button", json.dumps(observed))

            typed = cli.json("type-text", "smoke",
                             **{"role": "AXTextField", "title": "Session input", "text": "probe"})
            self.assertTrue(typed.get("ok"), typed)

            clicked = cli.json("click", "smoke",
                               **{"role": "AXButton", "title": "Session button"})
            self.assertTrue(clicked.get("ok"), clicked)
            observed = cli.json("observe", "smoke")
            self.assertIn("Session clicked", json.dumps(observed))

            status = cli.json("get-status", "smoke")
            chrome_session = self.payload(status).get("chromeSession") or {}
            self.assertEqual(chrome_session.get("mode"), "existing", status)
            self.assertTrue(chrome_session.get("brokerAlive"), status)

            stopped = cli.json("stop-workspace", "smoke")
            self.assertTrue(stopped.get("ok"), stopped)
            closed = self.payload(stopped).get("chromeSession") or {}
            self.assertTrue(closed.get("cleanupConfirmed"), stopped)

        self.assertTrue(self.chrome.alive(), "shared stop must never kill the bound Chrome")

    def test_shared_login_wall_blocks_mutation(self):
        cli = self.cli
        with FixtureHTTPServer(FIXTURES) as http:
            url = self.http_url(http, "session-login.html")
            cli.run("create-workspace", "wall", backend="cdp")
            launched = cli.json("launch-app", "wall", app="chrome",
                                **{"chrome-session": "existing", "url": url, "site": "fixture"})
            self.assertTrue(launched.get("ok"), launched)
            access = self.payload(launched).get("access", {})
            self.assertEqual(access.get("access"), "login_required", launched)

            click = cli.json("click", "wall", **{"role": "AXButton", "title": "Sign in"})
            self.assertFalse(click.get("ok"), click)
            self.assertIn("login_required", json.dumps(click))

            typed = cli.json("type-text", "wall",
                             **{"role": "AXTextField", "title": "Password", "text": "hunter2"})
            self.assertFalse(typed.get("ok"), typed)
            self.assertIn("password", json.dumps(typed).lower())

            handoff = cli.json("session-handoff", "wall")
            self.assertTrue(handoff.get("ok"), handoff)
            blocked = cli.json("observe", "wall")
            self.assertFalse(blocked.get("ok"), blocked)
            self.assertIn("handoff", json.dumps(blocked))
            resumed = cli.json("session-resume", "wall")
            self.assertFalse(resumed.get("ok"), resumed)
            self.assertEqual(resumed["error"]["code"], "login_required")

            cli.json("stop-workspace", "wall")

    def test_shared_redirect_to_login_wall_is_caught(self):
        cli = self.cli
        with FixtureHTTPServer(FIXTURES) as http:
            url = self.http_url(http, "session-redirect.html")
            cli.run("create-workspace", "redir", backend="cdp")
            launched = cli.json("launch-app", "redir", app="chrome",
                                **{"chrome-session": "existing", "url": url,
                                   "site": "fixture"})
            self.assertTrue(launched.get("ok"), launched)
            access = self.payload(launched).get("access", {})
            self.assertEqual(access.get("access"), "login_required", launched)
            click = cli.json("click", "redir", **{"role": "AXButton", "title": "Sign in"})
            self.assertFalse(click.get("ok"), click)
            self.assertIn("login_required", json.dumps(click))
            cli.json("stop-workspace", "redir")

    def test_shared_popup_and_download_policy(self):
        cli = self.cli
        with FixtureHTTPServer(FIXTURES) as http:
            url = self.http_url(http, "session-app.html")
            cli.run("create-workspace", "policy", backend="cdp")
            launched = cli.json("launch-app", "policy", app="chrome",
                                **{"chrome-session": "existing", "url": url,
                                   "site": "fixture", "expected-account": "alice@fixture.io"})
            self.assertTrue(launched.get("ok"), launched)

            clicked = cli.json("click", "policy",
                               **{"role": "AXLink", "title": "Download attachment"})
            self.assertFalse(clicked.get("ok"), clicked)
            self.assertEqual(clicked["error"]["code"], "download_refused")
            deadline = time.time() + 10
            blocked = 0
            while time.time() < deadline and blocked < 1:
                time.sleep(0.3)
                session = list(cli.journal()["sessions"].values())[0]
                blocked = session.get("downloadsBlocked", 0)
            self.assertGreaterEqual(blocked, 1, cli.journal())

            before_targets = {t["id"] for t in targets(self.chrome_root)}
            cli.json("click", "policy",
                     **{"role": "AXButton", "title": "Open popup via window.open"})
            self.assertEqual({t["id"] for t in targets(self.chrome_root)}, before_targets)
            time.sleep(1)
            journal = cli.journal()
            sessions = list(journal["sessions"].values())
            self.assertEqual(len(sessions), 1)
            self.assertEqual(len(sessions[0]["targets"]), 1)

            clicked = cli.json("click", "policy",
                               **{"role": "AXLink", "title": "Opens in a new tab"})
            self.assertFalse(clicked.get("ok"), clicked)
            self.assertEqual(clicked["error"]["code"], "account_unverified")
            self.assertTrue(clicked["error"]["details"]["dispatched"])
            self.assertFalse(clicked["error"]["details"]["verified"])
            self.assertFalse(clicked["error"]["details"]["retrySafe"])
            observed = cli.json("observe", "policy")
            self.assertFalse(observed.get("ok"), observed)
            self.assertNotIn("Popup target reached", json.dumps(observed))
            session = list(cli.journal()["sessions"].values())[0]
            self.assertEqual(len(session["targets"]), 1)

            log = cli.session_log_text()
            self.assertNotIn("127.0.0.1", log)
            self.assertNotIn("alice@fixture.io", log)
            self.assertNotIn("session-app", log)

            cli.json("stop-workspace", "policy")

    def test_shared_account_mismatch_blocks_everything(self):
        cli = self.cli
        with FixtureHTTPServer(FIXTURES) as http:
            url = self.http_url(http, "session-app.html")
            cli.run("create-workspace", "mismatch", backend="cdp")
            cli.json("launch-app", "mismatch", app="chrome",
                     **{"chrome-session": "existing", "url": url,
                        "site": "fixture", "expected-account": "bob@fixture.io"})
            observed = cli.json("observe", "mismatch")
            self.assertFalse(observed.get("ok"), observed)
            self.assertIn("account_unverified", json.dumps(observed))
            cli.json("stop-workspace", "mismatch")

    def test_shared_url_slot_never_proves_identity(self):
        cli = self.cli
        with FixtureHTTPServer(FIXTURES) as http:
            url = self.http_url(http, "session-popup-target.html") + "?authuser=2&u=/u/2/"
            cli.run("create-workspace", "slot", backend="cdp")
            cli.json("launch-app", "slot", app="chrome",
                     **{"chrome-session": "existing", "url": url,
                        "site": "fixture", "expected-account": "alice@fixture.io"})
            observed = cli.json("observe", "slot")
            self.assertFalse(observed.get("ok"), observed)
            self.assertEqual(observed["error"]["code"], "account_unverified")
            cli.json("stop-workspace", "slot")

    def test_dedicated_profile_lifecycle(self):
        cli = self.cli
        with FixtureHTTPServer(FIXTURES) as http:
            url = self.http_url(http, "session-app.html")
            cli.run("create-workspace", "ded", backend="cdp")
            launched = cli.json("launch-app", "ded", app="chrome",
                                **{"chrome-session": "dedicated", "profile": "fixprof",
                                   "url": url, "site": "fixture",
                                   "expected-account": "alice@fixture.io"})
            self.assertTrue(launched.get("ok"), launched)
            opened = self.payload(launched)
            self.assertEqual(opened.get("access", {}).get("access"), "accessible", launched)

            observed = cli.json("observe", "ded")
            self.assertTrue(observed.get("ok"), observed)
            self.assertIn("Session button", json.dumps(observed))

            clicked = cli.json("click", "ded",
                               **{"role": "AXLink", "title": "Download attachment"})
            self.assertTrue(clicked.get("ok"), clicked)
            downloads_root = None
            deadline = time.time() + 10
            saved = []
            while time.time() < deadline and not saved:
                time.sleep(0.3)
                session = list(cli.journal()["sessions"].values())[0]
                saved = session.get("downloadsSaved", [])
            self.assertTrue(saved, "journal never recorded a saved download")
            broker_dir = cli.broker_dirs()[0]
            session_id = list(cli.journal()["sessions"].keys())[0]
            downloads_root = broker_dir / "downloads" / session_id
            self.assertTrue(any(downloads_root.glob("*.bin")),
                            f"no download file under {downloads_root}")

            profile = self.state / "chrome-profiles" / "fixprof"
            self.assertTrue(profile.is_dir(), "dedicated profile dir missing")

            generation_pid = cli.journal()["generation"]["identity"]["browser"]["pid"]
            stopped = cli.json("stop-workspace", "ded")
            self.assertTrue(stopped.get("ok"), stopped)
            closed = self.payload(stopped).get("chromeSession") or {}
            self.assertTrue(closed.get("browserTerminated"), stopped)

            deadline = time.time() + 10
            while time.time() < deadline:
                probe = subprocess.run(["kill", "-0", str(generation_pid)],
                                       capture_output=True)
                if probe.returncode != 0:
                    break
                time.sleep(0.3)
            self.assertNotEqual(probe.returncode, 0,
                                f"owned browser pid {generation_pid} still alive")
            self.assertTrue(profile.is_dir(), "profile dir was deleted - must persist")
            self.assertTrue(self.chrome.alive())

    def test_account_change_invalidates_verified_access(self):
        cli = self.cli
        with FixtureHTTPServer(FIXTURES) as http:
            cli.run("create-workspace", "account-change", backend="cdp")
            launched = cli.json("launch-app", "account-change", app="chrome",
                                **{"chrome-session": "existing", "url": self.http_url(http, "account-first"),
                                   "site": "fixture", "expected-account": "alice@fixture.io"})
            self.assertTrue(launched.get("ok"), launched)
            self.assertEqual(self.payload(launched)["access"]["identity"], "verified")
            deadline = time.time() + 8
            while time.time() < deadline and not any(t["url"].endswith("/account-second") for t in targets(self.chrome_root)):
                time.sleep(.1)
            self.assertTrue(any(t["url"].endswith("/account-second") for t in targets(self.chrome_root)))
            try:
                observed = cli.json("observe", "account-change")
                self.assertFalse(observed.get("ok"), observed)
                self.assertIn("account_unverified", json.dumps(observed))
                typed = cli.json("type-text", "account-change",
                                 **{"role": "AXTextField", "title": "Session input", "text": "must not enter Bob's account"})
                self.assertFalse(typed.get("ok"), typed)
            finally:
                cli.json("stop-workspace", "account-change")

    def test_dedicated_cookie_is_reused_by_next_task(self):
        cli = self.cli
        with FixtureHTTPServer(FIXTURES) as http:
            cli.run("create-workspace", "cookie-first", backend="cdp")
            launched = cli.json("launch-app", "cookie-first", app="chrome",
                                **{"chrome-session": "dedicated", "profile": "cookie-proof",
                                   "url": self.http_url(http, "session-start"), "site": "fixture"})
            self.assertTrue(launched.get("ok"), launched)
            signed_in = cli.json("click", "cookie-first",
                                 **{"role": "AXLink", "title": "Sign in fixture"})
            self.assertTrue(signed_in.get("ok"), signed_in)
            for _ in range(50):
                observed = cli.json("observe", "cookie-first")
                if "Session button" in json.dumps(observed):
                    break
                time.sleep(.1)
            self.assertIn("Session button", json.dumps(observed))
            stopped = cli.json("stop-workspace", "cookie-first")
            self.assertTrue(stopped.get("ok"), stopped)
            cli.run("create-workspace", "cookie-second", backend="cdp")
            relaunched = cli.json("launch-app", "cookie-second", app="chrome",
                                 **{"chrome-session": "dedicated", "profile": "cookie-proof",
                                    "url": self.http_url(http, "session-protected"), "site": "fixture",
                                    "expected-account": "alice@fixture.io"})
            try:
                self.assertTrue(relaunched.get("ok"), relaunched)
                observed = cli.json("observe", "cookie-second")
                self.assertTrue(observed.get("ok"), observed)
                self.assertIn("Session button", json.dumps(observed))
            finally:
                cli.json("stop-workspace", "cookie-second")
                cli.json("stop-workspace", "cookie-first")

    def open_fixture(self, workspace, http, path, **options):
        self.cli.run("create-workspace", workspace, backend="cdp")
        reply = self.cli.json("launch-app", workspace, app="chrome", **{
            "chrome-session": "existing", "url": self.http_url(http, path), "site": "fixture", **options})
        self.assertTrue(reply.get("ok"), reply)
        return reply

    def owned_target(self, workspace):
        ref = json.loads((self.state / workspace / "workspace.json").read_text())["chromeSession"]
        record = self.cli.journal()["sessions"][ref["session"]]
        return record["targets"][-1]["targetId"]

    def test_expiry_blocks_input_after_verified_open(self):
        with FixtureHTTPServer(FIXTURES) as http:
            self.open_fixture("expiry", http, "session-short-set")
            time.sleep(1.5)
            control = CDP(endpoint(self.chrome_root))
            try:
                page = control.attach(self.owned_target("expiry"))
                control.send("Page.navigate", {"url": self.http_url(http, "session-protected")}, page)
                time.sleep(.2)
            finally:
                control.close()
            observed = self.cli.json("observe", "expiry")
            self.assertEqual(self.payload(observed)["access"]["access"], "login_required", observed)
            typed = self.cli.json("type-text", "expiry", role="AXTextField", title="Email", text="forbidden")
            self.assertFalse(typed.get("ok"), typed)
            self.assertEqual(typed["error"]["code"], "login_required")
            self.cli.json("stop-workspace", "expiry")

    def test_partial_open_has_stable_binding_and_provable_cleanup(self):
        before = {t["id"] for t in targets(self.chrome_root)}
        self.cli.run("create-workspace", "partial", backend="cdp")
        options = {"chrome-session": "existing", "url": f"http://127.0.0.1:{free_port()}/never"}
        failed = self.cli.json("launch-app", "partial", app="chrome", **options)
        self.assertFalse(failed.get("ok"), failed)
        created = {t["id"] for t in targets(self.chrome_root)} - before
        self.assertEqual(len(created), 1)
        retry = self.cli.json("launch-app", "partial", app="chrome", **options)
        self.assertFalse(retry.get("ok"), retry)
        self.assertEqual(retry["error"]["code"], "opening_incomplete")
        self.assertEqual({t["id"] for t in targets(self.chrome_root)} - before, created)
        stopped = self.cli.json("stop-workspace", "partial")
        self.assertTrue(stopped.get("ok"), stopped)
        self.assertEqual({t["id"] for t in targets(self.chrome_root)}, before)

    def test_dead_broker_and_missing_endpoint_preserve_uncertainty(self):
        with FixtureHTTPServer(FIXTURES) as http:
            launched = self.open_fixture("uncertain", http, "session-app.html")
            record = json.loads((self.cli.broker_dirs()[0] / "broker.json").read_text())
            os.kill(record["pid"], 9)
            (self.chrome_root / "DevToolsActivePort").unlink()
            stopped = self.cli.json("stop-workspace", "uncertain")
            self.assertFalse(stopped.get("ok"), stopped)
            self.assertEqual(stopped["error"]["code"], "cleanup_uncertain")
            status = self.cli.json("get-status", "uncertain")
            self.assertIsNotNone(self.payload(status)["workspace"].get("chromeSession"))
            self.chrome.stop()
            stopped = self.cli.json("stop-workspace", "uncertain")
            self.assertTrue(stopped.get("ok"), stopped)

    def test_dedicated_profile_reopens_after_dead_broker_cleanup(self):
        with FixtureHTTPServer(FIXTURES) as http:
            options = {"chrome-session":"dedicated", "profile":"crash-recovery", "url":self.http_url(http, "session-app.html")}
            self.cli.run("create-workspace", "crashed", backend="cdp")
            self.assertTrue(self.cli.json("launch-app", "crashed", app="chrome", **options).get("ok"))
            record = json.loads((self.cli.broker_dirs()[0] / "broker.json").read_text())
            os.kill(record["pid"], 9)
            stopped = self.cli.json("stop-workspace", "crashed")
            self.assertTrue(stopped.get("ok"), stopped)
            self.cli.run("create-workspace", "recovered", backend="cdp")
            opened = self.cli.json("launch-app", "recovered", app="chrome", **options)
            self.assertTrue(opened.get("ok"), opened)
            self.assertTrue(self.cli.json("observe", "recovered").get("ok"))
            self.assertTrue(self.cli.json("stop-workspace", "recovered").get("ok"))
            self.assertTrue(self.chrome.alive())

    def test_dedicated_profile_lease_rejects_sibling_without_killing_owner(self):
        with FixtureHTTPServer(FIXTURES) as http:
            options = {"chrome-session": "dedicated", "profile": "lease", "url": self.http_url(http, "session-app.html")}
            for name in ("owner", "sibling"):
                self.cli.run("create-workspace", name, backend="cdp")
            self.assertTrue(self.cli.json("launch-app", "owner", app="chrome", **options).get("ok"))
            refused = self.cli.json("launch-app", "sibling", app="chrome", **options)
            self.assertFalse(refused.get("ok"), refused)
            self.assertEqual(refused["error"]["code"], "profile_in_use")
            self.assertTrue(self.cli.json("stop-workspace", "sibling").get("ok"))
            self.assertTrue(self.cli.json("observe", "owner").get("ok"))
            self.assertTrue(self.cli.json("stop-workspace", "owner").get("ok"))

    def test_privacy_in_journal_failure_logs_and_inline_screenshot(self):
        with FixtureHTTPServer(FIXTURES) as http:
            self.open_fixture("privacy", http, "session-app.html?code=SECRET_QUERY#SECRET_FRAGMENT", **{"expected-account": "alice@fixture.io"})
            shot = self.cli.json("observe", "privacy", screenshot=True)
            self.assertTrue(shot.get("ok"), shot)
            self.assertIn("base64", self.payload(shot)["screenshot"])
            self.cli.json("stop-workspace", "privacy")
            self.cli.run("create-workspace", "failure", backend="cdp")
            self.cli.json("launch-app", "failure", app="chrome", **{"chrome-session": "existing", "url": "ftp://example.com/SECRET_FAILURE"})
            durable = "".join(p.read_text() for p in self.state.rglob("*")
                              if p.is_file() and p.suffix in (".json", ".jsonl"))
            for secret in ("SECRET_QUERY", "SECRET_FRAGMENT", "SECRET_FAILURE", "alice@fixture.io", "Session button", "lastURL", "fixture-account-readback"):
                self.assertNotIn(secret, durable)
            self.assertFalse(list(self.state.rglob("*.png")))

    def broker_rpc(self, op, fields=None, token=None, read_reply=True):
        directory = self.cli.broker_dirs()[0]
        record = json.loads((directory / "broker.json").read_text())
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(10)
            client.connect(record["socketPath"])
            request = {"op": op, "token": token if token is not None else (directory / "broker-token").read_text().strip(), **(fields or {})}
            client.sendall(json.dumps(request).encode() + b"\n")
            if read_reply:
                return json.loads(client.makefile("rb").readline())

    def test_close_waits_for_target_inventory_to_settle(self):
        with FixtureHTTPServer(FIXTURES) as http, CDPProxy(endpoint(self.chrome_root), close_visibility_delays=2) as proxy:
            root = self.tmp / "proxied"
            root.mkdir()
            from urllib.parse import urlsplit
            parsed = urlsplit(proxy.url)
            (root / "DevToolsActivePort").write_text(f"{parsed.port}\n{parsed.path}\n")
            self.cli = AgentSpaceCLI(self.state, root)
            self.open_fixture("close-wait", http, "session-app.html")
            target = self.owned_target("close-wait")
            stopped = self.cli.json("stop-workspace", "close-wait")
            self.assertTrue(stopped.get("ok"), stopped)
            self.assertNotIn(target, {t["id"] for t in targets(self.chrome_root)})
            self.assertEqual(proxy.close_visibility_delays, 0)
            self.assertEqual(sum(r["method"] == "Target.closeTarget" for r in proxy.requests), 1)

    def test_uncertain_close_is_retryable_on_same_connection(self):
        with FixtureHTTPServer(FIXTURES) as http, CDPProxy(endpoint(self.chrome_root), close_failures=1) as proxy:
            root = self.tmp / "proxied"
            root.mkdir()
            from urllib.parse import urlsplit
            parsed = urlsplit(proxy.url)
            (root / "DevToolsActivePort").write_text(f"{parsed.port}\n{parsed.path}\n")
            self.cli = AgentSpaceCLI(self.state, root)
            self.open_fixture("retry-close", http, "session-app.html")
            target = self.owned_target("retry-close")
            first = self.cli.json("stop-workspace", "retry-close")
            self.assertFalse(first.get("ok"), first)
            self.assertEqual(first["error"]["code"], "cleanup_uncertain")
            self.assertIn(target, {t["id"] for t in targets(self.chrome_root)})
            self.assertFalse(next(iter(self.cli.journal()["sessions"].values()))["ended"])
            second = self.cli.json("stop-workspace", "retry-close")
            self.assertTrue(second.get("ok"), second)
            self.assertNotIn(target, {t["id"] for t in targets(self.chrome_root)})
            self.assertEqual(proxy.connections, 1)
            self.assertEqual(sum(r["method"] == "SystemInfo.getProcessInfo" for r in proxy.requests), 1)

    def test_arming_failure_keeps_target_bound_for_stop(self):
        with FixtureHTTPServer(FIXTURES) as http, CDPProxy(endpoint(self.chrome_root), arm_failures=1) as proxy:
            root = self.tmp / "proxied"
            root.mkdir()
            from urllib.parse import urlsplit
            parsed = urlsplit(proxy.url)
            (root / "DevToolsActivePort").write_text(f"{parsed.port}\n{parsed.path}\n")
            self.cli = AgentSpaceCLI(self.state, root)
            before = {t["id"] for t in targets(self.chrome_root)}
            self.cli.run("create-workspace", "arm", backend="cdp")
            failed = self.cli.json("launch-app", "arm", app="chrome", **{
                "chrome-session":"existing", "url":self.http_url(http, "session-app.html")})
            self.assertFalse(failed.get("ok"), failed)
            self.assertEqual(len({t["id"] for t in targets(self.chrome_root)} - before), 1)
            target = next(iter(self.cli.journal()["sessions"].values()))["targets"][0]
            self.assertEqual(target["state"], "open")
            self.assertTrue(self.cli.json("stop-workspace", "arm").get("ok"))
            self.assertEqual({t["id"] for t in targets(self.chrome_root)}, before)
            self.assertEqual(proxy.connections, 1)

    def test_lost_close_reply_returns_settled_receipt(self):
        with FixtureHTTPServer(FIXTURES) as http:
            self.open_fixture("lost", http, "session-app.html")
            target = self.owned_target("lost")
            sid = next(iter(self.cli.journal()["sessions"]))
            self.broker_rpc("close-session", {"session": sid}, read_reply=False)
            deadline = time.time() + 5
            while time.time() < deadline and target in {t["id"] for t in targets(self.chrome_root)}:
                time.sleep(.1)
            receipt = self.broker_rpc("close-session", {"session": sid})
            self.assertTrue(receipt["cleanupConfirmed"], receipt)
            repeated = self.broker_rpc("close-session", {"session": sid})
            self.assertEqual(receipt, repeated)
            self.assertTrue(self.cli.json("stop-workspace", "lost").get("ok"))

    def test_ipc_bad_token_and_slow_peer_leave_other_calls_working(self):
        with FixtureHTTPServer(FIXTURES) as http:
            self.open_fixture("ipc", http, "session-app.html")
            reply = self.broker_rpc("status", token="wrong")
            self.assertEqual(reply["error"]["code"], "auth_failed")
            record = json.loads((self.cli.broker_dirs()[0] / "broker.json").read_text())
            with socket.socket(socket.AF_UNIX) as slow:
                slow.connect(record["socketPath"])
                slow.sendall(b'{"op":')
                self.assertTrue(self.cli.json("observe", "ipc").get("ok"))
            for raw, expected in ((b'not-json\n', "protocol_error"), (b'A' * (1100 * 1024), "request_too_large")):
                with socket.socket(socket.AF_UNIX) as invalid:
                    invalid.settimeout(5)
                    invalid.connect(record["socketPath"])
                    try: invalid.sendall(raw)
                    except BrokenPipeError: pass
                    response = json.loads(invalid.makefile("rb").readline())
                    self.assertEqual(response["error"]["code"], expected)
            self.cli.json("stop-workspace", "ipc")

    def test_last_session_broker_exits_after_bounded_idle(self):
        with FixtureHTTPServer(FIXTURES) as http:
            self.open_fixture("idle", http, "session-app.html")
            record = json.loads((self.cli.broker_dirs()[0] / "broker.json").read_text())
            self.assertTrue(self.cli.json("stop-workspace", "idle").get("ok"))
            deadline = time.time() + 40
            while time.time() < deadline:
                try: os.kill(record["pid"], 0)
                except ProcessLookupError: break
                time.sleep(.2)
            else:
                self.fail("last-session broker retained its privileged connection beyond the idle bound")
            self.assertTrue(self.chrome.alive())

    def test_actual_broker_flock_survives_simultaneous_startup(self):
        directory = self.tmp / "racing-broker"
        socket_path = self.tmp / "race.sock"
        args = [str(BIN_DIR / "agentspace-session-broker"), "--key", "sb-race", "--mode", "existing",
                "--chrome-root", str(self.chrome_root), "--broker-dir", str(directory), "--socket", str(socket_path)]
        children = [subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for _ in range(6)]
        try:
            deadline = time.time() + 5
            record_path = directory / "broker.json"
            while time.time() < deadline and not record_path.exists():
                time.sleep(.05)
            record = json.loads(record_path.read_text())
            inode = socket_path.stat().st_ino
            winner = next(p for p in children if p.pid == record["pid"])
            for child in children:
                if child is not winner:
                    self.assertNotEqual(child.wait(timeout=5), 0)
            self.assertIsNone(winner.poll())
            self.assertEqual(socket_path.stat().st_ino, inode)
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(5)
                client.connect(str(socket_path))
                token = (directory / "broker-token").read_text().strip()
                client.sendall(json.dumps({"op":"hello","token":token}).encode() + b"\n")
                reply = json.loads(client.makefile("rb").readline())
                self.assertTrue(reply["ok"], reply)
                self.assertEqual(reply["pid"], winner.pid)
        finally:
            for child in children:
                if child.poll() is None:
                    child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)

    def test_replacement_broker_identity_is_refused_before_stop(self):
        with FixtureHTTPServer(FIXTURES) as http:
            self.open_fixture("bound", http, "session-app.html")
            path = self.state / "bound" / "workspace.json"
            saved = path.read_text()
            data = json.loads(saved)
            data["chromeSession"]["brokerStart"] += 1
            path.write_text(json.dumps(data))
            self.assertFalse(self.cli.json("observe", "bound").get("ok"))
            failed = self.cli.json("stop-workspace", "bound")
            self.assertFalse(failed.get("ok"), failed)
            self.assertEqual(failed["error"]["code"], "cleanup_uncertain")
            path.write_text(saved)
            self.assertTrue(self.cli.json("stop-workspace", "bound").get("ok"))

    def test_post_action_readback_cannot_expose_switched_account(self):
        with FixtureHTTPServer(FIXTURES) as http:
            self.open_fixture("switch", http, "account-switch", **{"expected-account": "alice@fixture.io"})
            clicked = self.cli.json("click", "switch", role="AXLink", title="Switch account")
            self.assertFalse(clicked.get("ok"), clicked)
            self.assertEqual(clicked["error"]["code"], "account_unverified")
            self.assertNotIn("Bob private mailbox", json.dumps(clicked))
            self.cli.json("stop-workspace", "switch")

    def test_real_form_base_and_script_popups_never_create_tabs(self):
        with FixtureHTTPServer(FIXTURES) as http:
            control = CDP(endpoint(self.chrome_root))
            try:
                self.open_fixture("popups", http, "unsafe-controls")
                target = self.owned_target("popups")
                page = control.attach(target)
                before = {t["id"] for t in targets(self.chrome_root)}
                for role, title in [("AXLink", "Base target link"), ("AXButton", "Blank form"),
                                    ("AXButton", "Blank submitter"), ("AXButton", "Script form")]:
                    control.send("Page.navigate", {"url": self.http_url(http, "unsafe-controls")}, page)
                    time.sleep(.25)
                    clicked = self.cli.json("click", "popups", role=role, title=title)
                    self.assertTrue(clicked.get("ok"), clicked)
                    self.assertEqual({t["id"] for t in targets(self.chrome_root)}, before, title)
                self.cli.json("stop-workspace", "popups")
                self.assertEqual({t["id"] for t in targets(self.chrome_root)}, before - {target})
            finally:
                control.close()

    def test_child_frames_cannot_open_foreign_tabs(self):
        with FixtureHTTPServer(FIXTURES) as http:
            self.open_fixture("frames", http, "frame-controls")
            before = {t["id"] for t in targets(self.chrome_root)}
            for title in ("Local frame popup", "Local frame form", "Cross frame form", "Cross frame popup"):
                clicked = self.cli.json("click", "frames", role="AXButton", title=title)
                self.assertTrue(clicked.get("ok"), clicked)
                time.sleep(.1)
                self.assertEqual({t["id"] for t in targets(self.chrome_root)}, before, title)
            self.cli.json("stop-workspace", "frames")

    def test_cross_frames_are_reprotected_after_resume(self):
        with FixtureHTTPServer(FIXTURES) as http:
            self.open_fixture("frame-resume", http, "frame-controls")
            browser = CDP(endpoint(self.chrome_root))
            try:
                target = self.owned_target("frame-resume")
                page = browser.attach(target)
                other = next(t["id"] for t in targets(self.chrome_root) if t["id"] != target)
                downloads = self.tmp / "resume-downloads"
                downloads.mkdir()
                browser.send("Browser.setDownloadBehavior", {"behavior": "allow", "downloadPath": str(downloads)})
                for title in ("Cross frame popup", "Cross frame form", "Cross frame download"):
                    handoff = self.cli.json("session-handoff", "frame-resume")
                    self.assertTrue(handoff.get("ok"), handoff)
                    browser.send("Page.navigate", {"url": self.http_url(http, "frame-controls")}, page)
                    time.sleep(.3)
                    browser.send("Target.activateTarget", {"targetId": other})
                    resumed = self.cli.json("session-resume", "frame-resume")
                    self.assertTrue(resumed.get("ok"), resumed)
                    self.assertEqual(self.payload(resumed)["handoff"], "background")
                    before = {t["id"] for t in targets(self.chrome_root)}
                    clicked = self.cli.json("click", "frame-resume", role="AXButton", title=title)
                    self.assertTrue(clicked.get("ok"), clicked)
                    time.sleep(.2)
                    self.assertEqual({t["id"] for t in targets(self.chrome_root)}, before, title)
                    self.assertEqual(list(downloads.iterdir()), [], title)
                self.cli.json("stop-workspace", "frame-resume")
            finally:
                browser.close()

    def test_gmail_probe_requires_unique_account_in_top_banner(self):
        probe = subprocess.run([str(BIN_DIR / "agentspace-regression"), "--print-access-probe"],
                               capture_output=True, text=True, check=True, timeout=5).stdout
        with FixtureHTTPServer(FIXTURES) as http:
            self.open_fixture("gmail-dom", http, "gmail-probe")
            browser = CDP(endpoint(self.chrome_root))
            try:
                page = browser.attach(self.owned_target("gmail-dom"))
                facts = browser.evaluate(page, probe)
                self.assertTrue(facts["gmailMain"])
                self.assertEqual(facts["googleAccount"], "alice@fixture.io")
                browser.evaluate(page, "(()=>{const a=document.createElement('a');a.setAttribute('aria-label','Google Account: bob@fixture.io');document.querySelector('body>header').append(a);return true})()")
                self.assertIsNone(browser.evaluate(page, probe)["googleAccount"])
                browser.evaluate(page, "document.querySelector('body>header').remove();true")
                self.assertIsNone(browser.evaluate(page, probe)["googleAccount"])
                self.cli.json("stop-workspace", "gmail-dom")
            finally:
                browser.close()

    def test_handoff_restores_child_frames_and_modified_targets(self):
        with FixtureHTTPServer(FIXTURES) as http:
            self.open_fixture("restore", http, "restore-target")
            self.assertTrue(self.cli.json("click", "restore", role="AXLink", title="Retained target").get("ok"))
            human = CDP(endpoint(self.chrome_root))
            try:
                target = self.owned_target("restore")
                page = human.attach(target)
                self.assertEqual(human.evaluate(page, "document.querySelector('a').target"), "_self")
                self.assertTrue(self.cli.json("session-handoff", "restore").get("ok"))
                self.assertEqual(human.evaluate(page, "document.querySelector('a').target"), "_blank")
                human.send("Page.navigate", {"url":self.http_url(http, "frame-controls")}, page)
                time.sleep(.2)
                before = {t["id"] for t in targets(self.chrome_root)}
                human.evaluate(page, "!!document.getElementById('local').contentWindow.open('/session-app.html')")
                time.sleep(.2)
                self.assertEqual(len({t["id"] for t in targets(self.chrome_root)} - before), 1)
                self.cli.json("stop-workspace", "restore")
            finally:
                human.close()

    def test_separate_state_roots_have_distinct_socket_namespaces(self):
        with FixtureHTTPServer(FIXTURES) as http:
            self.open_fixture("first-root", http, "session-app.html")
            first_record = json.loads((self.cli.broker_dirs()[0] / "broker.json").read_text())
            other = AgentSpaceCLI(self.tmp / "other-state", self.chrome_root)
            try:
                other.run("create-workspace", "second-root", backend="cdp")
                opened = other.json("launch-app", "second-root", app="chrome", **{
                    "chrome-session":"existing", "url":self.http_url(http, "session-app.html")})
                self.assertTrue(opened.get("ok"), opened)
                second_record = json.loads((other.broker_dirs()[0] / "broker.json").read_text())
                self.assertNotEqual(first_record["socketPath"], second_record["socketPath"])
                self.assertTrue(other.json("stop-workspace", "second-root").get("ok"))
                self.assertTrue(self.cli.json("observe", "first-root").get("ok"))
                self.assertTrue(self.cli.json("stop-workspace", "first-root").get("ok"))
            finally:
                for directory in other.broker_dirs():
                    try: os.kill(json.loads((directory / "broker.json").read_text())["pid"], 15)
                    except ProcessLookupError: pass

    def test_broker_restart_does_not_reapprove_or_rebind_old_targets(self):
        with FixtureHTTPServer(FIXTURES) as http:
            self.open_fixture("old-broker", http, "session-app.html")
            record = json.loads((self.cli.broker_dirs()[0] / "broker.json").read_text())
            before = {t["id"] for t in targets(self.chrome_root)}
            os.kill(record["pid"], 9)
            time.sleep(.1)
            self.cli.run("create-workspace", "new-broker", backend="cdp")
            result = self.cli.json("launch-app", "new-broker", app="chrome", **{
                "chrome-session":"existing", "url":self.http_url(http, "session-app.html")})
            self.assertFalse(result.get("ok"), result)
            self.assertEqual(result["error"]["code"], "broker_recovery_required")
            self.assertEqual({t["id"] for t in targets(self.chrome_root)}, before)
            self.assertFalse(self.cli.json("stop-workspace", "old-broker").get("ok"))
            self.chrome.stop()
            self.assertTrue(self.cli.json("stop-workspace", "old-broker").get("ok"))

    def test_shared_download_guards_and_independent_human_download(self):
        with FixtureHTTPServer(FIXTURES) as http:
            control = CDP(endpoint(self.chrome_root))
            download_dir = self.tmp / "human-downloads"
            download_dir.mkdir()
            try:
                control.send("Browser.setDownloadBehavior", {"behavior": "allow", "downloadPath": str(download_dir)})
                self.open_fixture("downloads", http, "unsafe-controls")
                page = control.attach(self.owned_target("downloads"))
                for title in ("Plain download", "Data download", "Blob download"):
                    clicked = self.cli.json("click", "downloads", role="AXLink", title=title)
                    self.assertFalse(clicked.get("ok"), clicked)
                    self.assertEqual(clicked["error"]["code"], "download_refused")
                for role, title in (("AXButton", "Script download"), ("AXLink", "MIME download"), ("AXLink", "Header download")):
                    self.cli.json("click", "downloads", role=role, title=title)
                time.sleep(.3)
                self.assertFalse(list(download_dir.iterdir()), list(download_dir.iterdir()))
                human = next(t["id"] for t in targets(self.chrome_root) if t["id"] != self.owned_target("downloads"))
                human_page = control.attach(human)
                control.send("Page.navigate", {"url": self.http_url(http, "attached-file")}, human_page)
                deadline = time.time() + 5
                while time.time() < deadline and not (download_dir / "human-proof.bin").exists():
                    time.sleep(.1)
                self.assertEqual((download_dir / "human-proof.bin").read_bytes(), b"FIXTURE_DOWNLOAD_PROOF")
                observed = self.cli.json("observe", "downloads")
                self.assertTrue(observed.get("ok"), observed)
                self.cli.json("stop-workspace", "downloads")
            finally:
                control.close()

    def test_human_popup_handoff_restores_page_behavior_and_rearms(self):
        with FixtureHTTPServer(FIXTURES) as http:
            control = CDP(endpoint(self.chrome_root))
            try:
                downloads = self.tmp / "handoff-downloads"
                downloads.mkdir()
                control.send("Browser.setDownloadBehavior", {"behavior":"allow", "downloadPath":str(downloads)})
                self.open_fixture("human", http, "popup-login")
                target = self.owned_target("human")
                page = control.attach(target)
                before = {t["id"] for t in targets(self.chrome_root)}
                self.assertTrue(self.cli.json("session-handoff", "human").get("ok"))
                control.evaluate(page, "document.querySelector('a').click()")
                deadline = time.time() + 5
                while time.time() < deadline and not (downloads / "human-proof.bin").exists():
                    time.sleep(.1)
                self.assertEqual((downloads / "human-proof.bin").read_bytes(), b"FIXTURE_DOWNLOAD_PROOF")
                control.evaluate(page, "document.querySelector('button').click()")
                time.sleep(.5)
                created = {t["id"] for t in targets(self.chrome_root)} - before
                self.assertEqual(len(created), 1, targets(self.chrome_root))
                popup = created.pop()
                popup_page = control.attach(popup)
                self.assertTrue(control.evaluate(popup_page, "!!document.querySelector('[data-fixture-account]')"))
                self.assertEqual(len(next(iter(self.cli.journal()["sessions"].values()))["targets"]), 1)
                control.send("Page.navigate", {"url": self.http_url(http, "session-app.html")}, page)
                time.sleep(.2)
                other = next(t for t in before if t != target)
                control.send("Target.activateTarget", {"targetId": other})
                resumed = self.cli.json("session-resume", "human")
                self.assertTrue(resumed.get("ok"), resumed)
                count = len(targets(self.chrome_root))
                self.cli.json("click", "human", role="AXButton", title="Open popup via window.open")
                self.assertEqual(len(targets(self.chrome_root)), count)
                self.cli.json("stop-workspace", "human")
                self.assertIn(popup, {t["id"] for t in targets(self.chrome_root)})
            finally:
                control.close()

    @unittest.skipUnless(os.environ.get("AGENTSPACE_TEST_HEADED"), "requires isolated headed fixture")
    def test_dedicated_headed_handoff_relaunch(self):
        cli = self.cli
        with FixtureHTTPServer(FIXTURES) as http:
            cli.run("create-workspace", "ded-h", backend="cdp")
            launched = cli.json("launch-app", "ded-h", app="chrome", **{
                "chrome-session": "dedicated", "profile": "fixprof-h", "url": self.http_url(http, "session-start"),
                "site": "fixture", "expected-account": "alice@fixture.io"})
            self.assertTrue(launched.get("ok"), launched)
            headless_pid = cli.journal()["generation"]["identity"]["browser"]["pid"]
            handoff = cli.json("session-handoff", "ded-h")
            self.assertTrue(handoff.get("ok"), handoff)
            headed_pid = cli.journal()["generation"]["identity"]["browser"]["pid"]
            self.assertNotEqual(headed_pid, headless_pid)
            self.assertFalse(cli.json("observe", "ded-h").get("ok"))
            profile = self.state / "chrome-profiles" / "fixprof-h"
            human = CDP(endpoint(profile))
            try:
                page = human.attach(self.owned_target("ded-h"))
                human.evaluate(page, "document.querySelector('a').click()")
                deadline = time.time() + 5
                while time.time() < deadline and not human.evaluate(page, "!!document.querySelector('[data-fixture-account]')"):
                    time.sleep(.1)
            finally:
                human.close()
            resumed = cli.json("session-resume", "ded-h")
            self.assertTrue(resumed.get("ok"), resumed)
            self.assertEqual(self.payload(resumed).get("handoff"), "background", resumed)
            self.assertNotEqual(cli.journal()["generation"]["identity"]["browser"]["pid"], headed_pid)
            observed = cli.json("observe", "ded-h")
            self.assertTrue(observed.get("ok"), observed)
            self.assertEqual(self.payload(observed)["access"]["identity"], "verified")
            self.assertIn("Session button", json.dumps(observed))
            cli.json("stop-workspace", "ded-h")

    @unittest.skipUnless(os.environ.get("AGENTSPACE_TEST_HEADED"), "requires isolated headed fixture")
    def test_headed_human_focus_input_and_scroll_survive_background_work(self):
        self.chrome.stop()
        self.chrome_root = self.tmp / "headed-control"
        self.chrome = FixtureChrome(self.chrome_root, headed=True)
        self.chrome.wait_ready()
        self.cli = AgentSpaceCLI(self.state, self.chrome_root)
        with FixtureHTTPServer(FIXTURES) as http:
            human = CDP(endpoint(self.chrome_root))
            try:
                control_target = targets(self.chrome_root)[0]["id"]
                page = human.attach(control_target)
                human.send("Page.navigate", {"url": self.http_url(http, "control")}, page)
                time.sleep(.3)
                human.send("Target.activateTarget", {"targetId": control_target})
                human.evaluate(page, "document.getElementById('human').focus();scrollTo(0,300);true")
                human.send("Input.insertText", {"text": "human-before"}, page)
                state_expr = "({visible:document.visibilityState,focus:document.activeElement.id,value:document.getElementById('human').value,y:scrollY,hasFocus:document.hasFocus()})"
                before = human.evaluate(page, state_expr)
                self.assertEqual(before["visible"], "visible")
                self.assertEqual(before["focus"], "human")
                self.assertTrue(before["hasFocus"], before)
                self.open_fixture("background", http, "session-app.html", **{"expected-account": "alice@fixture.io"})
                for command, opts in [("observe", {}), ("type-text", {"role":"AXTextField","title":"Session input","text":"agent-input"}),
                                      ("click", {"role":"AXButton","title":"Session button"}), ("scroll", {"direction":"down"})]:
                    result = self.cli.json(command, "background", **opts)
                    self.assertTrue(result.get("ok"), result)
                    self.assertFalse(result["focusChanged"], result)
                    self.assertFalse(result["cursorMoved"], result)
                    self.assertEqual(human.evaluate(page, state_expr), before)
                human.send("Input.insertText", {"text":"-human-after"}, page)
                self.assertEqual(human.evaluate(page, state_expr)["value"], "human-before-human-after")
                self.cli.json("stop-workspace", "background")
                self.assertIn(control_target, {t["id"] for t in targets(self.chrome_root)})
            finally:
                human.close()

    def test_mcp_exposes_session_commands(self):
        cli = self.cli
        with FixtureHTTPServer(FIXTURES) as http:
            url = self.http_url(http, "session-app.html")
            tools, outputs = cli.mcp([
                ("create-workspace", {"backend": "cdp"}),
                ("launch-app", {"app": "chrome", "chrome-session": "existing",
                                "url": url, "site": "fixture",
                                "expected-account": "alice@fixture.io"}),
                ("observe", {}),
                ("session-handoff", {}),
                ("session-resume", {}),
                ("stop-workspace", {}),
            ])
            for needed in ("session-handoff", "session-resume", "observe", "launch-app"):
                self.assertIn(needed, tools)
            for (output, is_error) in outputs:
                self.assertTrue(output.get("ok"), output)
                self.assertFalse(is_error, output)
            self.assertIn("Session button", json.dumps(outputs[2][0]))


if __name__ == "__main__":
    unittest.main()
