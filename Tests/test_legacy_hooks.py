import json
import subprocess
import tempfile
import unittest
from pathlib import Path


class LegacyHookCleanupTests(unittest.TestCase):
    def test_removes_only_bugu_entries_and_backs_up_original(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            config = home / ".workbuddy/settings.json"
            config.parent.mkdir(parents=True)
            original = {
                "preference": {"theme": "dark"},
                "hooks": {
                    "Stop": [{"hooks": [
                        {"type": "command", "command": "/tmp/.bugu/bin/bugu-bridge --event Stop"},
                        {"type": "command", "command": "my-own-hook"},
                    ]}],
                    "Start": [{"hooks": [{"type": "command", "command": "another-hook"}]}],
                },
            }
            config.write_text(json.dumps(original))
            script = Path(__file__).parents[1] / "script/remove_legacy_hooks.py"
            subprocess.run(["python3", str(script), "--home", str(home)], check=True, capture_output=True)
            self.assertEqual(json.loads(config.read_text()), original)
            subprocess.run(["python3", str(script), "--home", str(home), "--apply"], check=True, capture_output=True)
            updated = json.loads(config.read_text())
            self.assertEqual(updated["preference"], original["preference"])
            self.assertEqual(updated["hooks"]["Stop"][0]["hooks"], [{"type": "command", "command": "my-own-hook"}])
            self.assertEqual(updated["hooks"]["Start"], original["hooks"]["Start"])
            backup = config.with_name(config.name + ".before-bugu-passive")
            self.assertEqual(json.loads(backup.read_text()), original)


if __name__ == "__main__":
    unittest.main()
