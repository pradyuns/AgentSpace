import base64
import hashlib
import json
import os
import socket
import socketserver
import struct
import threading
import urllib.parse
import urllib.request


def recv_exact(sock, count):
    result = b""
    while len(result) < count:
        chunk = sock.recv(count - len(result))
        if not chunk:
            raise EOFError("socket closed")
        result += chunk
    return result


def recv_frame(sock):
    head = recv_exact(sock, 2)
    length = head[1] & 127
    if length == 126:
        length = struct.unpack("!H", recv_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", recv_exact(sock, 8))[0]
    mask = recv_exact(sock, 4) if head[1] & 128 else None
    payload = recv_exact(sock, length)
    if mask:
        payload = bytes(v ^ mask[i % 4] for i, v in enumerate(payload))
    if head[0] & 15 == 8:
        raise EOFError("websocket closed")
    return payload


def send_frame(sock, value, masked=False):
    payload = json.dumps(value).encode()
    prefix = bytes([129])
    bit = 128 if masked else 0
    if len(payload) < 126:
        prefix += bytes([bit | len(payload)])
    elif len(payload) < 65536:
        prefix += bytes([bit | 126]) + struct.pack("!H", len(payload))
    else:
        prefix += bytes([bit | 127]) + struct.pack("!Q", len(payload))
    if masked:
        mask = os.urandom(4)
        prefix += mask
        payload = bytes(v ^ mask[i % 4] for i, v in enumerate(payload))
    sock.sendall(prefix + payload)


def read_headers(sock):
    data = b""
    while not data.endswith(b"\r\n\r\n"):
        data += recv_exact(sock, 1)
        if len(data) > 16384:
            raise ValueError("large upgrade headers")
    return data.decode()


class CDP:
    def __init__(self, endpoint):
        url = urllib.parse.urlsplit(endpoint)
        self.sock = socket.create_connection((url.hostname, url.port), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f"GET {url.path} HTTP/1.1\r\nHost: {url.hostname}:{url.port}\r\n"
                           f"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                           "Sec-WebSocket-Version: 13\r\n\r\n").encode())
        headers = read_headers(self.sock)
        if headers.splitlines()[0].split()[1] != "101":
            self.sock.close()
            raise RuntimeError(headers)
        self.serial = 0

    def send(self, method, params=None, session=None):
        self.serial += 1
        request = {"id": self.serial, "method": method, "params": params or {}}
        if session:
            request["sessionId"] = session
        send_frame(self.sock, request, masked=True)
        while True:
            response = json.loads(recv_frame(self.sock))
            if response.get("id") == self.serial:
                if "error" in response:
                    raise RuntimeError(response["error"])
                return response.get("result", {})

    def attach(self, target):
        return self.send("Target.attachToTarget", {"targetId": target, "flatten": True})["sessionId"]

    def evaluate(self, session, expression):
        response = self.send("Runtime.evaluate", {"expression": expression, "returnByValue": True,
                                                   "awaitPromise": True, "userGesture": True}, session)
        if "exceptionDetails" in response:
            raise RuntimeError(response["exceptionDetails"])
        return response.get("result", {}).get("value")

    def close(self):
        self.sock.close()


def endpoint(root):
    port, path, *_ = (root / "DevToolsActivePort").read_text().splitlines()
    return f"ws://127.0.0.1:{port}{path}"


def targets(root):
    port = (root / "DevToolsActivePort").read_text().splitlines()[0]
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=5) as response:
        return [t for t in json.load(response) if t["type"] == "page"]


class SocketFixture:
    def __init__(self, mode):
        self.mode = mode
        self.connections = 0
        self.requests = []
        fixture = self

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                fixture.connections += 1
                self.request.settimeout(10)
                try:
                    headers = read_headers(self.request)
                    key = next(line.split(":", 1)[1].strip() for line in headers.splitlines()
                               if line.lower().startswith("sec-websocket-key:"))
                    accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
                    self.request.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                                          f"Connection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n").encode())
                    while True:
                        request = json.loads(recv_frame(self.request))
                        fixture.requests.append(request)
                        if mode == "disconnect":
                            return
                        if mode == "overflow":
                            for i in range(400):
                                send_frame(self.request, {"method": "Fetch.requestPaused", "params": {"requestId": str(i)}})
                            return
                        if mode == "unresolved":
                            continue
                        send_frame(self.request, {"id": request["id"], "result": {"receipt": request["id"]}})
                except (EOFError, OSError, ValueError):
                    pass

        self.server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.url = f"ws://127.0.0.1:{self.server.server_address[1]}/devtools/browser/socket-test"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.server.shutdown()
        self.server.server_close()


class CDPProxy(SocketFixture):
    def __init__(self, upstream, close_failures=0, arm_failures=0, close_visibility_delays=0):
        import select
        proxy = self
        self.connections = 0
        self.requests = []
        self.close_failures = close_failures
        self.arm_failures = arm_failures
        self.close_visibility_delays = close_visibility_delays

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                proxy.connections += 1
                remote = None
                methods = {}
                cached_inventory = None
                closing = False
                try:
                    headers = read_headers(self.request)
                    key = next(line.split(":", 1)[1].strip() for line in headers.splitlines()
                               if line.lower().startswith("sec-websocket-key:"))
                    remote = CDP(upstream)
                    accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
                    self.request.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                                          f"Connection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n").encode())
                    while True:
                        ready, _, _ = select.select([self.request, remote.sock], [], [], 10)
                        if not ready:
                            continue
                        for source in ready:
                            frame = json.loads(recv_frame(source))
                            if source is self.request:
                                proxy.requests.append(frame)
                                method = frame.get("method")
                                if method == "Target.closeTarget" and proxy.close_failures:
                                    proxy.close_failures -= 1
                                    send_frame(self.request, {"id": frame["id"], "result": {"success": False}})
                                    continue
                                if method == "Page.addScriptToEvaluateOnNewDocument" and proxy.arm_failures:
                                    proxy.arm_failures -= 1
                                    send_frame(self.request, {"id": frame["id"], "error": {"code": -32000, "message": "fixture arming failure"}})
                                    continue
                                if method == "Target.closeTarget":
                                    closing = True
                                if method == "Target.getTargets" and closing and proxy.close_visibility_delays and cached_inventory:
                                    proxy.close_visibility_delays -= 1
                                    send_frame(self.request, {"id": frame["id"], "result": cached_inventory})
                                    continue
                                methods[frame["id"]] = method
                                send_frame(remote.sock, frame, masked=True)
                            else:
                                if methods.pop(frame.get("id"), None) == "Target.getTargets":
                                    cached_inventory = frame.get("result")
                                send_frame(self.request, frame)
                except (EOFError, OSError, ValueError):
                    pass
                finally:
                    if remote:
                        remote.close()

        self.server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        path = urllib.parse.urlsplit(upstream).path
        self.url = f"ws://127.0.0.1:{self.server.server_address[1]}{path}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
