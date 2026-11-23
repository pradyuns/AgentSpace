import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from mcp_adapter import Adapter, MCPClient, ToolError, munim_nodes, node, options, spaceo_nodes


class ParsingTests(unittest.TestCase):
    def test_agentspace_structured_application_error_is_preserved(self):
        client = MCPClient.__new__(MCPClient)
        client.tool = "agentspace"
        output = {"ok": False, "error": {"code": "element_not_found", "message": "Missing ref"}}
        response = {"isError": True, "content": [{"type": "text", "text": json.dumps(output)}]}
        client.request = lambda *args: {"result": response}
        self.assertEqual(client.call("click"), response)
        self.assertEqual(json.loads(client.call("click")["content"][0]["text"]), output)

    def test_unstructured_and_empty_mcp_errors_still_raise(self):
        client = MCPClient.__new__(MCPClient)
        client.tool = "agentspace"
        for content in [[], [{"type": "text", "text": "declined"}],
                        [{"type": "text", "text": "[]"}],
                        [{"type": "text", "text": '{"ok": false, "error": {}}'}]]:
            client.request = lambda *args: {"result": {"isError": True, "content": content}}
            with self.subTest(content=content), self.assertRaises(ToolError):
                client.call("click")

    def test_competitor_error_policy_is_unchanged(self):
        client = MCPClient.__new__(MCPClient)
        response = {"isError": True, "content": [{"type": "text", "text":
            '{"ok": false, "error": {"code": "element_not_found"}}'}]}
        client.request = lambda *args: {"result": response}
        for tool in ["spaceo", "munim", "opencomputer"]:
            client.tool = tool
            with self.subTest(tool=tool), self.assertRaises(ToolError):
                client.call("click")

    def test_spaceo_visual_coordinates_and_unaddressed_web_type(self):
        class Client:
            tool = "spaceo"
            process = type("Process", (), {"pid": 1})()

            def __init__(self):
                self.calls = []

            def call(self, name, args):
                self.calls.append((name, args))
                return {"content": []}

            def emit(self, *args):
                pass

        client = Client()
        adapter = Adapter(client)
        adapter.workspaces["web"] = {"kind": "chrome"}
        for command, arguments in [
            ("click", ["--x", "198", "--y", "104"]),
            ("drag", ["--x", "126", "--y", "173", "--to-x", "400", "--to-y", "173"]),
            ("move", ["--x", "100", "--y", "255"]),
            ("scroll", ["--x", "100", "--y", "390", "--dy", "-400", "--ticks", "1"]),
        ]:
            result = adapter.execute({"command": command, "workspace": "web", "arguments": arguments})
            self.assertTrue(result["ok"], result)
            self.assertEqual(client.calls[-1][0], "spaceo_"+command)
            self.assertTrue(client.calls[-1][1]["web"])
        result = adapter.execute({"command": "type-text", "workspace": "web", "arguments": ["--text", "VISUAL"]})
        self.assertTrue(result["ok"], result)
        self.assertEqual(client.calls[-1], ("spaceo_type", {"session": "web", "text": "VISUAL", "web": True}))

    def test_opencomputer_coordinate_input_is_unsupported(self):
        class Client:
            tool = "opencomputer"
            process = type("Process", (), {"pid": 1})()

            def emit(self, *args):
                pass

        adapter = Adapter(Client())
        adapter.workspaces["web"] = {"kind": "chrome"}
        result = adapter.execute({"command": "click", "workspace": "web", "arguments": ["--x", "1", "--y", "2"]})
        self.assertEqual(result["error"]["code"], "unsupported")

    def test_options(self):
        self.assertEqual(options(["--text", "line\nline", "--screenshot"]), {"text": "line\nline", "screenshot": True})
        self.assertEqual(options([]), {})

    def test_spaceo_native_outline(self):
        nodes = spaceo_nodes("    [0] TextArea — ONE\nTWO [focused]\n  [1] CheckBox — Probe checkbox [checked]\n  StaticText — Button clicked")
        self.assertEqual(nodes[0]["value"], "ONE\nTWO")
        self.assertEqual(nodes[1]["value"], "1")
        self.assertEqual(nodes[2]["value"], "Button clicked")
        self.assertEqual(spaceo_nodes(""), [])

    def test_munim_outline(self):
        nodes = munim_nodes('  [e3] TextField "Probe input" value="ONE\\nTWO"\n [e4] Button "Clicked"\n StaticText "Button clicked"')
        self.assertEqual(nodes[0]["value"], "ONE\nTWO")
        self.assertEqual(nodes[1]["ref"], "e4")
        self.assertEqual(nodes[2]["value"], "Button clicked")
        self.assertEqual(munim_nodes(""), [])

    def test_tool_error_is_not_unsupported(self):
        class Client:
            tool = "agentspace"
            process = type("Process", (), {"pid": 1})()

            def call(self, *args):
                raise ToolError("declined")

            def emit(self, *args):
                pass

        result = Adapter(Client()).execute({"command": "observe", "workspace": "test"})
        self.assertEqual(result["error"]["code"], "tool_error")

    def test_explicit_backend_unsupported_is_not_a_generic_tool_failure(self):
        class Client:
            tool = "spaceo"
            process = type("Process", (), {"pid": 1})()

            def call(self, *args):
                raise ToolError("[unsupported_target] no supported background delivery")

            def emit(self, *args):
                pass

        result = Adapter(Client()).execute({"command": "create-workspace", "workspace": "test"})
        self.assertEqual(result["error"]["code"], "unsupported")

    def test_munim_uses_own_read_for_ax_append_and_empty_replace(self):
        class Client:
            tool = "munim"
            process = type("Process", (), {"pid": 1})()
            calls = []

            def call(self, name, args):
                self.calls.append((name, args))

            def emit(self, *args):
                pass

        client = Client()
        adapter = Adapter(client)
        adapter.workspaces["test"] = {"kind": "textedit"}
        adapter.find = lambda *args: {"ref": "e1", "value": "OLD"}
        result = adapter.execute({"command": "type-text", "workspace": "test", "arguments": ["--text", "NEW"]})
        self.assertTrue(result["ok"])
        self.assertEqual(client.calls[-1], ("set_value", {"element_id": "e1", "value": "OLDNEW"}))
        adapter.execute({"command": "type-text", "workspace": "test", "arguments": ["--text", "", "--replace"]})
        self.assertEqual(client.calls[-1][1]["value"], "")

    def test_munim_chrome_bridge_blocker_never_uses_desktop_input(self):
        class Client:
            tool = "munim"
            process = type("Process", (), {"pid": 1})()

            def call(self, name, args):
                if name == "browser_open_tab":
                    return {"content": [{"type": "text", "text": "opened file:///fixture as tab 2 in the agent window (id 3)"}]}
                if name == "browser_snapshot":
                    self.tab = args["tab_id"]
                    raise ToolError("Chrome's native host is not connected")
                if name == "browser_close_tab":
                    self.closed = args["index"]
                    return {"content": []}
                raise AssertionError("Unexpected desktop input: "+name)

            def emit(self, *args):
                pass

        client = Client()
        adapter = Adapter(client)
        adapter.execute({"command": "create-workspace", "workspace": "test"})
        result = adapter.execute({"command": "launch-app", "workspace": "test", "arguments": ["--app", "chrome", "--file", "/fixture"]})
        self.assertEqual(result["error"]["code"], "unsupported")
        self.assertEqual(client.tab, 2)
        result = adapter.execute({"command": "click", "workspace": "test", "arguments": ["--title", "Probe button"]})
        self.assertEqual(result["error"]["code"], "unsupported")
        self.assertTrue(adapter.execute({"command": "stop-workspace", "workspace": "test"})["ok"])
        self.assertEqual(client.closed, 2)

    def test_close_audits_owned_apps_only_even_when_cleanup_errors(self):
        class Client:
            tool = "opencomputer"
            events = []

            def emit(self, *args):
                self.events.append(args)

        client = Client()
        adapter = Adapter(client)
        adapter.workspaces = {"unowned": {"ownedPIDs": []}, "owned": {"ownedPIDs": [123]}}
        calls = []
        adapter.perform = lambda *args: calls.append(args)
        with patch("mcp_adapter.alive", return_value=False):
            adapter.close()
        self.assertEqual(calls, [("stop-workspace", "owned", {})])
        self.assertEqual(client.events[-1][1]["leftoverPIDs"], [])
        adapter.perform = lambda *args: (_ for _ in ()).throw(ToolError("cleanup declined"))
        with patch("mcp_adapter.alive", return_value=True):
            adapter.close()
        self.assertEqual(client.events[-1][1]["leftoverPIDs"], [123])
        self.assertEqual(client.events[-2][0], "adapter.cleanup_error")

    def test_find_waits_for_controls_and_bounds_missing_elements(self):
        class Client:
            tool = "spaceo"

        adapter = Adapter(Client())
        adapter.workspaces["test"] = {"nodes": []}
        observations = []

        def observe(*args):
            observations.append(True)
            adapter.workspaces["test"]["nodes"] = [node("TextField", "Ready", ref="1")] if len(observations) > 1 else []

        adapter.observe = observe
        with patch("mcp_adapter.time.sleep") as settle:
            self.assertEqual(adapter.find("test", {"title": "Ready"})["ref"], "1")
            settle.assert_called_once_with(.1)
        with patch("mcp_adapter.time.sleep") as settle:
            with self.assertRaises(ToolError):
                adapter.find("test", {"title": "Missing"})
            self.assertEqual(settle.call_count, 20)

    def test_opencomputer_scroll_accepts_already_reached_marker(self):
        class Client:
            tool = "opencomputer"
            process = type("Process", (), {"pid": 1})()

            def call(self, name, args):
                self.action = (name, args)

            def emit(self, *args):
                pass

        client = Client()
        adapter = Adapter(client)
        adapter.workspaces["test"] = {"app": "com.apple.Safari", "snapshot": "fresh", "nodes": [node("Button", "Bottom marker: reached", ref="9")]}
        adapter.observe = lambda *args: None
        self.assertTrue(adapter.execute({"command": "scroll", "workspace": "test"})["ok"])
        self.assertEqual(client.action[1]["element"], 9)

    def test_spaceo_unconfirmed_scroll_requires_own_read_and_capture(self):
        class Client:
            tool = "spaceo"
            process = type("Process", (), {"pid": 1})()
            failure = "[unsupported_target] delivery unconfirmed"

            def call(self, *args):
                raise ToolError(self.failure)

            def emit(self, *args):
                pass

        client = Client()
        adapter = Adapter(client)
        state = {"nodes": []}
        adapter.workspaces["test"] = state
        adapter.find = lambda *args: {"ref": "1"}
        request = {"command": "scroll", "workspace": "test", "arguments": ["--direction", "down"]}
        for reached, captured, expected in ((True, True, True), (False, True, False), (True, False, False), (False, False, False)):
            with self.subTest(reached=reached, captured=captured):
                state["nodes"] = [node("Button", "Bottom marker: reached")] if reached else []
                adapter.observe = lambda *args, **kwargs: {"screenshot": {"path": "fixture.png"}} if captured else {}
                result = adapter.execute(request)
                self.assertEqual(result["ok"], expected)
                if not expected:
                    self.assertEqual(result["error"]["code"], "unsupported")
        client.failure = "[unsupported_target] no supported background delivery"
        self.assertEqual(adapter.execute(request)["error"]["code"], "unsupported")
        client.failure = "transport failed"
        self.assertEqual(adapter.execute(request)["error"]["code"], "tool_error")

    def test_spaceo_native_value_or_explicit_unsupported(self):
        with tempfile.TemporaryDirectory() as directory:
            class Client:
                tool = "spaceo"
                process = type("Process", (), {"pid": 1})()
                serial = 0
                found = True
                fail_read = False

                def call(self, name, args):
                    if name == "spaceo_screenshot":
                        return {"content": [{"type": "image", "data": "AA=="}]}
                    if name == "spaceo_find":
                        value = "[3] TextField — Probe input" if self.found else "no matches"
                    elif name == "spaceo_read_screen":
                        value = "[w0] input type=text — Probe input  at (10,10)"
                    elif args.get("element"):
                        if self.fail_read:
                            raise ToolError("read declined")
                        value = "field value\ntext (accessibility):\nACTUAL"
                    else:
                        value = "page text"
                    return {"content": [{"type": "text", "text": value}]}

                def emit(self, *args):
                    pass

            client = Client()
            client.directory = Path(directory)
            adapter = Adapter(client)
            adapter.workspaces["test"] = {"kind": "chrome"}
            request = {"command": "observe", "workspace": "test", "arguments": ["--screenshot"]}
            result = adapter.execute(request)
            self.assertTrue(result["ok"])
            self.assertEqual(result["result"]["tree"]["children"][0]["value"], "ACTUAL")
            client.found = False
            self.assertEqual(adapter.execute(request)["error"]["code"], "unsupported")
            client.found, client.fail_read = True, True
            self.assertEqual(adapter.execute(request)["error"]["code"], "tool_error")

    def test_opencomputer_normalizes_description_as_label(self):
        class Client:
            tool = "opencomputer"
            process = type("Process", (), {"pid": 1})()

            def call(self, *args):
                data = {"snapshot": "fresh", "nodes": [{"id": 1, "role": "AXTextField", "description": "smart search field", "value": "file:///fixture"}]}
                return {"content": [{"type": "text", "text": json.dumps(data)}]}

            def emit(self, *args):
                pass

        adapter = Adapter(Client())
        adapter.workspaces["test"] = {"app": "com.apple.Safari"}
        result = adapter.execute({"command": "observe", "workspace": "test"})
        field = result["result"]["tree"]["children"][0]
        self.assertEqual(field["label"], "smart search field")
        self.assertEqual(field["value"], "file:///fixture")

    def test_opencomputer_preparation_waits_for_late_focus_guard(self):
        class Client:
            tool = "opencomputer"
            process = type("Process", (), {"pid": 1})()

            def call(self, *args):
                return {"content": [{"type": "text", "text": '{"launched":true,"pid":123}'}]}

            def emit(self, *args):
                pass

        with patch("mcp_adapter.time.sleep") as settle:
            result = Adapter(Client()).execute({"command": "prepare", "workspace": "test"})
        self.assertTrue(result["ok"])
        settle.assert_called_once_with(2)


class LiveProtocolTests(unittest.TestCase):
    @unittest.skipUnless(Path(".build/release/agentspace").exists(), "build agentspace first")
    def test_stdio_initialize_list_empty_and_error(self):
        with tempfile.TemporaryDirectory() as directory:
            client = MCPClient("agentspace", directory)
            try:
                self.assertIn("observe", [schema["name"] for schema in client.schemas])
                self.assertTrue(json.loads(client.call("list-workspaces")["content"][0]["text"])["ok"])
                with self.assertRaises(ToolError):
                    client.call("missing")
                client.call("create-workspace", {"workspace": "protocol-test"})
                client.call("stop-workspace", {"workspace": "protocol-test"})
            finally:
                client.close()


if __name__ == "__main__":
    unittest.main()
