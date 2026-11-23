"""Native launch must attempt the host, without creating a real display or app."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class NativeLaunchTests(unittest.TestCase):
    def test_first_launch_spawns_host_and_keeps_failure_recoverable(self):
        root = Path(__file__).resolve().parent.parent
        binary = Path(os.environ.get("AGENTSPACE_BIN", root / ".build/release/agentspace"))
        if not binary.is_file():
            self.skipTest("build agentspace first")
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            host = home / "failing-host"
            host.write_text("#!/usr/bin/env python3\nfrom pathlib import Path\n"
                            "Path(__file__).with_suffix('.started').touch()\nraise SystemExit(43)\n")
            host.chmod(0o700)
            env = dict(os.environ, AGENTSPACE_HOME=str(home / "state"), AGENTSPACE_DISPLAY_HOST=str(host))

            def call(*args):
                p = subprocess.run([str(binary), *args, "--workspace", "first"],
                                   env=env, capture_output=True, text=True, timeout=30)
                return json.loads(p.stdout)

            self.assertTrue(call("create-workspace", "--backend", "virtual-display")["ok"])
            launched = call("launch-app", "--app", "textedit")
            self.assertFalse(launched["ok"])
            self.assertTrue(host.with_suffix(".started").exists(), launched)
            self.assertIn(launched["error"]["code"], ["host_spawn_failed", "host_unreachable", "host_io", "host_closed"], launched)
            status = call("get-status")
            self.assertTrue(status["ok"], status)
            self.assertEqual(status["result"]["workspace"]["apps"], [])
            self.assertTrue(call("stop-workspace")["ok"])
