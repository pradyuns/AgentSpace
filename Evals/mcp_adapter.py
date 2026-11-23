import base64
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import sys
import threading
import time


class Unsupported(Exception):
    pass


class ToolError(Exception):
    pass


def options(arguments):
    result = {}
    index = 0
    while index < len(arguments):
        key = arguments[index].removeprefix("--")
        index += 1
        if index == len(arguments) or arguments[index].startswith("--"):
            result[key] = True
        else:
            result[key] = arguments[index]
            index += 1
    return result


def node(role, title="", value=None, ref=None):
    result = {"role": role if role.startswith("AX") else "AX"+role,
              "title": title, "label": title, "children": []}
    if value is not None:
        result["value"] = str(value).lower() if isinstance(value, bool) else str(value)
    if ref is not None:
        result["ref"] = str(ref)
    return result


def spaceo_nodes(screen):
    """Parse the documented native outline, preserving multiline values."""
    nodes = []
    pattern = re.compile(r"^([ ]*)(?:\[([w0-9]+)\] )?([A-Z][A-Za-z]+)(?: — (.*))?$")
    for line in screen.splitlines():
        web = re.match(r"\s*\[(w\d+)\] (input type=(?:text|checkbox)|textarea|button|a) — (.*?)\s+at \((-?[\d.]+),(-?[\d.]+)\)", line)
        if web:
            ref, kind, detail, x, y = web.groups()
            role = {"input type=text": "TextField", "input type=checkbox": "CheckBox", "textarea": "TextArea", "button": "Button", "a": "Link"}[kind]
            checked = "[checked]" in detail
            detail = re.sub(r"\s+\[(?:checked|unchecked)\]", "", detail).strip()
            title, separator, value = detail.partition(" · value: ")
            item = node(role, title, value if separator else "1" if checked else "0" if role == "CheckBox" else "" if role in ("TextField", "TextArea") else None, ref)
            item["point"] = {"x": float(x), "y": float(y)}
            nodes.append(item)
            continue
        match = pattern.match(line)
        if not match:
            if nodes and nodes[-1]["role"] in ("AXTextArea", "AXTextField") and not line.startswith(" "):
                nodes[-1]["value"] = nodes[-1].get("value", "")+"\n"+line.removesuffix(" [focused]")
            continue
        _, ref, role, detail = match.groups()
        detail = detail or ""
        checked = " [checked]" in detail
        detail = re.sub(r"\s+\((?:disabled)\)|\s+\[(?:focused|checked|unchecked|collapsed|expanded)\]", "", detail)
        title, separator, value = detail.partition(" · value: ")
        if role in ("TextArea", "StaticText") and not separator:
            value = title
            if role in ("TextArea", "TextField"):
                title = ""
        elif role == "CheckBox":
            value = "1" if checked else "0"
        elif not separator:
            value = None
        nodes.append(node(role, title, value, ref))
    return nodes


def munim_nodes(screen):
    nodes = []
    quoted = r'"(?:[^"\\]|\\.)*"'
    pattern = re.compile(r'^\s*(?:\[(e\d+)\] )?([A-Z][A-Za-z]+)(?: ('+quoted+r'))?(?: value=('+quoted+r'))?')
    for line in screen.splitlines():
        match = pattern.match(line)
        if not match:
            continue
        ref, role, label, value = match.groups()
        label = json.loads(label) if label else ""
        value = json.loads(value) if value else label if role == "StaticText" else "" if role in ("TextField", "TextArea") else None
        if role == "CheckBox":
            value = "1" if "(checked)" in line or value == "1" else "0"
        nodes.append(node(role, label, value, ref))
    return nodes


class MCPClient:
    def __init__(self, tool, directory, binary=None):
        self.tool = tool
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.log = (self.directory / "mcp.jsonl").open("a")
        self.sequence = 0
        self.serial = 0
        self.broken = False
        competitors = Path(os.environ.get("AGENTSPACE_COMPETITORS", Path.home() / "competitors"))
        commands = {
            "agentspace": [str(binary or Path(".build/release/agentspace").resolve()), "mcp"],
            "spaceo": [str(competitors / "SpaceO/.build/release/spaceo"), "mcp"],
            "munim": [str(competitors / "munim-computer-use/macos/.build/release/munim-computer-use")],
            "opencomputer": ["node", str(competitors / "opencomputer/bin/opencomputer.mjs"), "serve"],
        }
        env = os.environ.copy()
        env["AGENTSPACE_HOME"] = os.environ.get("AGENTSPACE_ADAPTER_STATE", str(self.directory / "state"))
        env["SPACEO_SOCKET"] = str(Path("Evals/results/comparison-setup/spaceo.sock").resolve())
        env["OPENCOMPUTER_APPS"] = "com.apple.TextEdit,com.apple.Safari,agent-browser"
        self.errors = (self.directory / "server-stderr.log").open("a")
        start = time.monotonic()
        self.process = subprocess.Popen(commands[tool], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.errors, env=env)
        self.responses = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()
        self.request("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                    "clientInfo": {"name": "agentspace-comparison", "version": "1"}})
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        self.schemas = self.request("tools/list", {})["result"]["tools"]
        self.emit("mcp.server_started", {"pid": self.process.pid, "latencyMs": (time.monotonic()-start)*1000,
                                         "tool": tool})

    def emit(self, kind, payload):
        self.sequence += 1
        stamp = time.time()+float(os.environ["AGENTSPACE_CLOCK_OFFSET"]) if "AGENTSPACE_CLOCK_OFFSET" in os.environ else time.monotonic()
        self.log.write(json.dumps({"sequence": self.sequence, "time": stamp, "trial": "adapter",
                                   "kind": kind, "payload": payload}, separators=(",", ":"))+"\n")
        self.log.flush()

    def _read(self):
        try:
            for line in self.process.stdout:
                self.responses.put(json.loads(line))
        except Exception as error:
            self.responses.put({"readerError": str(error)})
        finally:
            self.responses.put(None)

    def send(self, request):
        self.emit("mcp.request", request)
        self.process.stdin.write((json.dumps(request, separators=(",", ":"))+"\n").encode())
        self.process.stdin.flush()

    def request(self, method, params):
        if self.broken:
            raise ToolError("MCP transport unusable after timed out request")
        self.serial += 1
        identifier = self.serial
        start = time.monotonic()
        self.send({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params})
        deadline = start + 30
        while True:
            try:
                response = self.responses.get(timeout=max(.01, deadline-time.monotonic()))
            except queue.Empty:
                self.broken = True
                self.process.terminate()
                raise ToolError("MCP request timed out")
            self.emit("mcp.response", response)
            if response is None:
                raise ToolError("MCP server closed stdout")
            if response.get("id") == identifier:
                if "error" in response:
                    raise ToolError(json.dumps(response["error"]))
                self.emit("mcp.latency", {"method": method, "name": params.get("name"),
                                          "latencyMs": (time.monotonic()-start)*1000})
                return response
            if time.monotonic() >= deadline:
                raise ToolError("MCP request timed out")

    def call(self, name, arguments=None):
        response = self.request("tools/call", {"name": name, "arguments": arguments or {}})["result"]
        if response.get("isError"):
            if self.tool == "agentspace":
                try:
                    output = payload(response)
                    if (isinstance(output, dict) and output.get("ok") is False
                            and isinstance(output.get("error"), dict)
                            and isinstance(output["error"].get("code"), str)):
                        return response
                except (ValueError, TypeError):
                    pass
            raise ToolError(json.dumps(response))
        return response

    def close(self):
        try:
            self.process.stdin.close()
            self.process.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            self.process.terminate()
            self.process.wait(timeout=5)
        self.errors.close()
        self.process.stdout.close()
        self.log.close()


def text(result):
    return "\n".join(block.get("text", "") for block in result.get("content", []) if block.get("type") == "text")


def payload(result):
    return json.loads(text(result))


def image(result, destination):
    for block in result.get("content", []):
        if block.get("type") == "image":
            destination.write_bytes(base64.b64decode(block["data"], validate=True))
            return str(destination)
    return None


class Adapter:
    def __init__(self, client):
        self.client = client
        self.tool = client.tool
        self.workspaces = {}

    def call(self, name, arguments=None):
        try:
            return self.client.call(name, arguments)
        except ToolError as error:
            if self.tool == "spaceo" and "[unsupported_target]" in str(error):
                raise Unsupported(str(error)) from error
            raise

    def close(self):
        for workspace, state in self.workspaces.items():
            if state.get("ownedPIDs"):
                if not state.get("stopped"):
                    try:
                        self.perform("stop-workspace", workspace, {})
                    except Exception as error:
                        self.client.emit("adapter.cleanup_error", {"workspace": workspace, "error": str(error)})
                self.client.emit("adapter.cleanup", {"workspace": workspace,
                    "leftoverPIDs": [pid for pid in state["ownedPIDs"] if alive(pid)]})

    def observe(self, workspace, screenshot=False):
        state = self.workspaces[workspace]
        if self.tool == "spaceo":
            result = self.call("spaceo_read_screen", {"session": workspace, "full": True})
            state["rawScreen"] = text(result)
            state["nodes"] = spaceo_nodes(text(result))
            if state.get("kind") != "textedit":
                reading = text(self.call("spaceo_read_text", {"session": workspace}))
                state["rawScreen"] += "\n" + reading
                if "text (" in reading:
                    body = reading.split("text (", 1)[1].split(":\n", 1)[-1]
                    state["nodes"].extend(node("StaticText", value=line) for line in body.splitlines())
        elif self.tool == "opencomputer":
            args = {"app": state["app"], "format": "json"}
            if state.get("windowTitle"):
                args["windowTitle"] = state["windowTitle"]
            data = payload(self.call("observe", args))
            state["snapshot"] = data["snapshot"]
            state["nodes"] = [dict(n, ref=str(n["id"]), children=[],
                                   title=n.get("title", n.get("description", "")),
                                   label=n.get("title", n.get("description", "")),
                                   value=str(n["value"]).lower() if isinstance(n.get("value"), bool)
                                   else str(n["value"]) if "value" in n else "") for n in data["nodes"]]
        elif self.tool == "munim":
            result = self.call("get_app_state", {"app": state["app"], "window": "agent", "offscreen": True})
            state["nodes"] = munim_nodes(text(result))
        else:
            raise Unsupported("No adapter observation for this tool")
        result = {"tree": {"role": "AXApplication", "children": state["nodes"]},
                  "outline": state.get("rawScreen", "")}
        if screenshot:
            start = time.monotonic()
            args = {"session": workspace} if self.tool == "spaceo" else {"app": state["app"]}
            data = self.call("spaceo_screenshot" if self.tool == "spaceo" else "screenshot", args)
            if self.tool == "opencomputer":
                metadata = payload(data)
                if metadata.get("selectionRequired"):
                    match = next((w for w in metadata["windows"] if state.get("windowTitle", "AgentSpace Fixture") in w.get("title", "")), None)
                    if not match:
                        raise ToolError("Screenshot did not list the disposable window")
                    data = self.call("screenshot", dict(args, windowId=match["windowId"]))
            destination = self.client.directory / (workspace+"-"+str(self.client.serial)+".png")
            path = image(data, destination)
            result["screenshot"] = {"path": path, "latencyMs": (time.monotonic()-start)*1000}
            if self.tool == "spaceo" and state.get("kind") != "textedit":
                for control in state["nodes"]:
                    if control["role"] not in ("AXTextField", "AXTextArea") or "ref" not in control:
                        continue
                    if control["ref"].startswith("w"):
                        found = spaceo_nodes(text(self.call("spaceo_find", {"session": workspace, "query": control["title"],
                                                                           "role": control["role"].removeprefix("AX")})))
                        target = next((n for n in found if n.get("ref", "").isdigit()), None)
                        if not target:
                            raise Unsupported("No native AX field reference for own-value verification; web read_text omits form values")
                        read = text(self.call("spaceo_read_text", {"session": workspace, "element": target["ref"]}))
                        control["value"] = read.split(":\n", 1)[1] if ":\n" in read else ""
                    else:
                        read = text(self.call("spaceo_read_text", {"session": workspace, "element": control["ref"]}))
                        control["value"] = read.split(":\n", 1)[1] if ":\n" in read else ""
        if state.pop("preparation", False) and self.tool == "opencomputer":
            self.call("release")
        return result

    def find(self, workspace, args):
        for attempt in range(21):
            self.observe(workspace)
            candidates = self.workspaces[workspace]["nodes"]
            for key in ("role", "title", "ref"):
                if key in args:
                    candidates = [n for n in candidates if n.get(key) == args[key]]
            index = int(args.get("index", 0))
            if index < len(candidates):
                return candidates[index]
            if attempt < 20:
                time.sleep(.1)
        raise ToolError("Element not found after bounded readiness polling: "+json.dumps(args))

    def perform(self, command, workspace, args):
        if self.tool == "agentspace":
            arguments = dict(args, workspace=workspace)
            return payload(self.call(command, arguments))
        if command == "prepare":
            self.perform("create-workspace", workspace, {})
            result = self.perform("launch-app", workspace, dict(args, app="chrome"))
            if self.tool == "opencomputer":
                time.sleep(2)
            self.workspaces[workspace]["preparation"] = True
            return result
        if command == "create-workspace":
            if self.tool == "spaceo":
                self.call("spaceo_session_create", {"name": workspace, "preset": "exclusive_1080p"})
            self.workspaces[workspace] = {"nodes": [], "ownedPIDs": []}
            return {"ok": True, "result": {}}
        state = self.workspaces[workspace]
        if state.get("blocker") and command != "stop-workspace":
            raise Unsupported(state["blocker"])
        if self.tool == "spaceo" and "x" in args and command in ("click", "drag", "move", "scroll"):
            action = {"session": workspace, "x": float(args["x"]), "y": float(args["y"]),
                      "web": state.get("kind") == "chrome"}
            if command == "drag":
                action.update(to_x=float(args["to-x"]), to_y=float(args["to-y"]))
            if command == "scroll":
                action.update(dy=int(args["dy"]), ticks=int(args.get("ticks", 1)))
            self.call("spaceo_"+command, action)
            return {"ok": True, "result": {}}
        if self.tool == "opencomputer" and "x" in args:
            raise Unsupported("OpenComputer MCP has only element-addressed pointer actions, not coordinate input")
        if command == "launch-app":
            kind = args["app"]
            bundle = {"textedit": "com.apple.TextEdit", "chrome": "com.google.Chrome", "safari": "com.apple.Safari"}[kind]
            state["kind"] = kind
            file = args.get("file")
            if self.tool == "spaceo":
                launch = {"app": bundle, "session": workspace}
                if file:
                    launch["files"] = [file]
                raw = text(self.call("spaceo_open_app", launch))
                match = re.search(r"launched .*?\(pid (\d+)\)", raw)
                if match:
                    state["ownedPIDs"].append(int(match[1]))
            elif self.tool == "opencomputer":
                state["app"] = "agent-browser" if kind == "chrome" else bundle
                if kind == "textedit":
                    fixture = self.client.directory / (workspace+".txt")
                    fixture.write_text("")
                    file = str(fixture.resolve())
                    state["windowTitle"] = fixture.name
                launch = {"app": state["app"]}
                if file:
                    launch["url"] = Path(file).resolve().as_uri()
                data = payload(self.call("open", launch))
                state["targetPID"] = data.get("pid")
                if data.get("launched") and kind == "chrome":
                    state["ownedPIDs"].append(data["pid"])
            else:
                if kind == "textedit":
                    self.call("launch_app", {"app": bundle})
                    screen = text(self.call("get_app_state", {"app": bundle}))
                    if "a dialog is open" in screen:
                        raise Unsupported("SETUP_BLOCKED: existing TextEdit has an autosave modal; launch_app reuses it and cannot open a disposable file/new instance")
                    raise Unsupported("No open-file/new-instance tool for a disposable TextEdit document while preserving existing documents")
                if kind == "safari":
                    raise Unsupported("Safari URL opening is not exposed; browser_* targets Chrome")
                try:
                    result = text(self.call("browser_open_tab", {"url": Path(file).resolve().as_uri()}))
                    state["tab"] = result
                    state["app"] = bundle
                    tab = re.search(r"tab_id=(\d+)|as tab (\d+)", result)
                    if not tab:
                        raise ToolError("Browser open did not return a tab reference")
                    if tab[2]:
                        state["tabIndex"] = int(tab[2])
                    self.call("browser_snapshot", {"tab_id": int(tab[1] or tab[2])})
                except ToolError as error:
                    if "native host is not connected" in str(error):
                        raise Unsupported("SETUP_BLOCKED: Chrome browser tools require the native-host/extension connection; desktop Chrome input is explicitly prohibited by the server instructions; no installer or registration permitted")
                    raise
                raise Unsupported("Chrome snapshot does not expose field values for exact own-read verification in this adapter")
            pid = state["ownedPIDs"][0] if state["ownedPIDs"] else state.get("targetPID")
            return {"ok": True, "result": {"app": {"pid": pid, "kind": kind, "owned": bool(pid)},
                                               "openedURL": Path(file).resolve().as_uri() if file else None}}
        if command == "observe":
            return {"ok": True, "result": self.observe(workspace, bool(args.get("screenshot")))}
        if command == "stop-workspace":
            if self.tool == "spaceo":
                self.call("spaceo_session_destroy", {"session": workspace})
            elif self.tool == "opencomputer":
                if state.get("ownedPIDs"):
                    if any(alive(pid) for pid in state["ownedPIDs"]):
                        self.call("menu", {"app": state["app"], "pid": state["ownedPIDs"][0], "path": "Chrome > Quit Google Chrome", "changes": False})
                    deadline = time.monotonic()+5
                    while time.monotonic() < deadline:
                        if all(not alive(pid) for pid in state["ownedPIDs"]):
                            break
                        time.sleep(.05)
                elif state.get("windowTitle"):
                    self.observe(workspace)
                    close = next((n for n in state["nodes"] if n.get("subrole") == "AXCloseButton"), None)
                    if not close:
                        raise ToolError("No close control on the disposable document")
                    self.call("click", {"app": state["app"], "snapshot": state["snapshot"], "element": int(close["ref"]), "changes": False})
                self.call("release")
            else:
                if state.get("kind") != "chrome":
                    raise Unsupported("No owned-app lifecycle/termination tool")
                if "tabIndex" in state:
                    self.call("browser_close_tab", {"index": state["tabIndex"]})
                else:
                    self.call("browser_close_all_tabs")
            return {"ok": True, "result": {"ownedPIDs": state["ownedPIDs"]}}
        if self.tool == "munim" and command in ("type-text", "click", "scroll"):
            if state.get("kind") == "chrome":
                raise Unsupported("Desktop Chrome input is prohibited by the server instructions; use connected browser tools")
            if command == "scroll":
                self.observe(workspace)
                self.call("scroll", {"direction": args.get("direction", "down"), "amount": 30})
            else:
                target = self.find(workspace, args)
                if not target.get("ref"):
                    raise ToolError("Element has no actionable reference")
                if command == "click":
                    self.call("click", {"element_id": target["ref"]})
                else:
                    value = args["text"] if args.get("replace") else target.get("value", "")+args["text"]
                    self.call("set_value", {"element_id": target["ref"], "value": value})
        elif command == "key" and self.tool == "spaceo":
            self.call("spaceo_press_key", {"session": workspace, "key": args["key"]})
        elif command == "type-text" and self.tool == "spaceo":
            if state["kind"] != "textedit" and any(k in args for k in ("role", "title", "ref")):
                target = self.find(workspace, args)
                if target.get("ref"):
                    self.call("spaceo_click", {"session": workspace, "element": target["ref"]})
                else:
                    self.call("spaceo_click", {"session": workspace, "label": args["title"], "role": args["role"].removeprefix("AX")})
            self.call("spaceo_type", {"session": workspace, "text": args["text"], "web": state["kind"] == "chrome"})
        elif command == "click" and self.tool == "spaceo":
            target = self.find(workspace, args)
            action = {"session": workspace}
            if target.get("ref"):
                action["element"] = target["ref"]
            else:
                action.update(label=target["title"], role=target["role"].removeprefix("AX"))
            self.call("spaceo_click", action)
        elif command == "scroll" and self.tool == "spaceo":
            target = self.find(workspace, {"role": "AXLink", "title": "Jump to bottom"})
            try:
                self.call("spaceo_scroll", {"session": workspace, "element": target["ref"], "dy": -600 if args.get("direction") == "down" else 600, "ticks": 10})
            except Unsupported as error:
                if "unconfirmed" not in str(error) or args.get("direction") != "down":
                    raise
                observation = self.observe(workspace, screenshot=True)
                reached = any(n.get("title") == "Bottom marker: reached" or n.get("value") == "Bottom marker: reached"
                              for n in state["nodes"])
                if not reached or not observation.get("screenshot", {}).get("path"):
                    raise error
                return {"ok": True, "result": {"verification": "own-read+capture", "capturePath": observation["screenshot"]["path"]}}
        elif self.tool == "opencomputer" and command in ("type-text", "key", "click", "scroll"):
            if command == "scroll":
                self.observe(workspace)
                target = next((n for n in state["nodes"] if n["role"] == "AXButton" and n.get("title", "").startswith("Bottom marker:")), None)
                if not target:
                    raise ToolError("No observed bottom marker")
                self.call("performAction", {"app": state["app"], "snapshot": state["snapshot"],
                                            "element": int(target["ref"]), "action": "AXScrollToVisible", "changes": False})
                return {"ok": True, "result": {}}
            select = args if command in ("type-text", "click") else {"role": "AXTextArea"}
            target = self.find(workspace, select)
            action = {"app": state["app"], "snapshot": state["snapshot"], "element": int(target["ref"]), "changes": False}
            method = {"type-text": "typeText", "key": "pressKey", "click": "click"}[command]
            if command == "type-text":
                action["text"] = args["text"]
            elif command == "key":
                action["key"] = args["key"]
            self.call(method, action)
        else:
            raise Unsupported("Tool does not expose "+command)
        return {"ok": True, "result": {}}

    def execute(self, request):
        command, workspace = request["command"], request["workspace"]
        start = time.monotonic()
        try:
            output = self.perform(command, workspace, options(request.get("arguments", [])))
        except Unsupported as error:
            if command in ("launch-app", "prepare"):
                self.workspaces[workspace]["blocker"] = str(error)
            output = {"ok": False, "error": {"code": "unsupported", "message": str(error)}}
        except ToolError as error:
            output = {"ok": False, "error": {"code": "tool_error", "message": str(error)}}
        except Exception as error:
            output = {"ok": False, "error": {"code": "adapter_error", "message": repr(error)}}
        output["serverPID"] = self.client.process.pid
        if command == "stop-workspace" and output.get("ok") and workspace in self.workspaces:
            self.workspaces[workspace]["stopped"] = True
        self.client.emit("adapter.action", {"command": command, "workspace": workspace,
                                            "output": output, "latencyMs": (time.monotonic()-start)*1000})
        return output


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


if __name__ == "__main__":
    client = MCPClient(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    adapter = Adapter(client)
    try:
        for line in sys.stdin:
            print(json.dumps(adapter.execute(json.loads(line)), separators=(",", ":")), flush=True)
    finally:
        adapter.close()
        client.close()
